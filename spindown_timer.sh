#!/usr/bin/env bash

# ##################################################
# TrueNAS HDD Spindown Timer
# Monitors drive I/O and forces HDD spindown after a given idle period.
#
# Version: 2.0.1
#
# See: https://github.com/ngandrass/truenas-spindown-timer
#
#
# MIT License
# 
# Copyright (c) 2022 Niels Gandraß <niels@gandrass.de>
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
# ##################################################

TIMEOUT=3600               # Default timeout before considering a drive as idle
POLL_TIME=600              # Default time to wait during a single iostat call
IGNORED_DRIVES=""          # Default list of drives that are never spun down
MANUAL_MODE=0              # Default manual mode setting
QUIET=0                    # Default quiet mode setting
VERBOSE=0                  # Default verbosity level
DRYRUN=0                   # Default for dryrun option
SHUTDOWN_TIMEOUT=0         # Default shutdown timeout (0 == no shutdown)
declare -A DRIVES          # Associative array for detected drives
DISK_PARM_TOOL=camcontrol  # Default disk parameter tool to use (camcontrol OR hdparm)

##
# Prints the help/usage message
##
function print_usage() {
    cat << EOF
Usage: $0 [-h] [-q] [-v] [-d] [-m] [-t TIMEOUT] [-p POLL_TIME] [-i DRIVE] [-s TIMEOUT]

Monitors drive I/O and forces HDD spindown after a given idle period.
Resistant to S.M.A.R.T. reads.

A drive is considered as idle and is spun down if there has been no I/O
operations on it for at least TIMEOUT seconds. I/O requests are detected
during intervals with a length of POLL_TIME seconds. Detected reads or
writes reset the drives timer back to TIMEOUT.

Options:
  -q           : Quiet mode. Outputs are suppressed if flag is present.
  -v           : Verbose mode. Prints additonal information during execution.
  -d           : Dry run. No actual spindown is performed.
  -m           : Manual mode. If this flag is set, the automatic drive detection
                 is disabled.
                 This inverts the -i switch which then needs to be used to supply
                 each drive to monitor. All other drives will be ignored.
  -t TIMEOUT   : Number of seconds to wait for I/O in total before considering
                 a drive as idle.
  -p POLL_TIME : Number of seconds to wait for I/O during a single iostat call.
  -i DRIVE     : In automatic drive detection mode (default): Ignores the given
                 drive and never issue a spindown command for it.
                 In manual mode [-m]: Only monitor the specified drives.
                 Multiple drives can be given by repeating the -i switch.
  -s TIMEOUT   : Shutdown timeout, if no drive is active for TIMEOUT seconds, 
                 the system will be shut down 
  -h           : Print this help message.

Example usage:
$0
$0 -q -t 3600 -p 600 -i ada0 -i ada1
$0 -q -m -i ada6 -i ada7 -i da0
EOF
}

##
# Writes argument $1 to stdout if $QUIET is not set
#
# Arguments:
#   $1 Message to write to stdout
##
function log() {
    if [[ $QUIET -eq 0 ]]; then
        echo $1
    fi
}

##
# Writes argument $1 to stdout if $VERBOSE is set and $QUIET is not set
#
# Arguments:
#   $1 Message to write to stdout
##
function log_verbose() {
    if [[ $VERBOSE -eq 1 ]]; then
        if [[ $QUIET -eq 0 ]]; then
            echo $1
        fi
    fi
}

##
# Writes argument $1 to stderr. Ignores $QUIET.
#
# Arguments:
#   $1 Message to write to stderr
##
function log_error() {
    >&2 echo "[ERROR]: $1"
}

##
# Determines which tool to access disk parameters is available. This
# differentiates between TrueNAS Core and TrueNAS SCALE.
#
# Return: Command to use to access disk parameters
#
##
function detect_disk_parm_tool() {
    local SUPPORTED_DISK_PARM_TOOLS
    SUPPORTED_DISK_PARM_TOOLS="camcontrol hdparm"

    for tool in ${SUPPORTED_DISK_PARM_TOOLS}; do
        if [[ -n $(which ${tool}) ]]; then
            echo "${tool}"
            return
        fi
    done

    log_error "No supported disk parameter tool found."
    exit 1
}

##
# Detects all connected drives and whether they are ATA or SCSI drives.
# Drives listed in $IGNORE_DRIVES will be excluded.
#
# Note: This function populates the $DRIVES array directly.
##
function detect_drives() {
    local DRIVE_IDS

    # Detect relevant drives identifiers
    if [[ $MANUAL_MODE -eq 1 ]]; then
        # In manual mode the ignored drives become the explicitly monitored drives
        DRIVE_IDS=" ${IGNORED_DRIVES} "
    else
        DRIVE_IDS=`iostat -x | grep -E '^(ada|da|sd)' | awk '{printf $1 " "}'`
        DRIVE_IDS=" ${DRIVE_IDS} " # Space padding must be kept for pattern matching

        # Remove ignored drives
        for drive in ${IGNORED_DRIVES[@]}; do
            DRIVE_IDS=`sed "s/ ${drive} / /g" <<< ${DRIVE_IDS}`
        done
    fi

    # Detect protocol type (ATA or SCSI) for each drive and populate $DRIVES array
    local DISK_IS_ATA
    for drive in ${DRIVE_IDS}; do
        case $DISK_PARM_TOOL in
            "camcontrol") DISK_IS_ATA=$(camcontrol identify $drive |& grep -E "^protocol(.*)ATA");;
            "hdparm") DISK_IS_ATA=$(hdparm -I "/dev/$drive" |& grep -E "^ATA device");;
        esac

        if [[ -n $DISK_IS_ATA ]]; then
            DRIVES[$drive]="ATA"
        else
            DRIVES[$drive]="SCSI"
        fi
    done
}

##
# Retrieves the list of identifiers (e.g. "ada0") for all monitored drives.
# Drives listed in $IGNORE_DRIVES will be excluded.
#
# Note: Must be run after detect_drives().
##
function get_drives() {
    echo "${!DRIVES[@]}"
}

##
# Waits $1 seconds and returns a list of all drives that didn't
# experience I/O operations during that period.
#
# Devices listed in $IGNORED_DRIVES will never get returned.
#
# Arguments:
#   $1 Seconds to listen for I/O before drives are considered idle
##
function get_idle_drives() {
    # Wait for $1 seconds and get active drives
    local IOSTAT_OUTPUT=`iostat -x -z -d $1 2`
    case $DISK_PARM_TOOL in
        "camcontrol")
            local CUT_OFFSET=`grep -no "extended device statistics" <<< ${IOSTAT_OUTPUT} | tail -n1 | grep -Eo '^[^:]+'` ;;
        "hdparm")
            local CUT_OFFSET=`grep -no "Device" <<< ${IOSTAT_OUTPUT} | tail -n1 | grep -Eo '^[^:]+'` ;;
    esac
    local ACTIVE_DRIVES=`tail -n +$((CUT_OFFSET+2)) <<< ${IOSTAT_OUTPUT} | awk '{printf $1}{printf " "}'`

    # Remove active drives from list to get idle drives
    local IDLE_DRIVES=" $(get_drives) " # Space padding must be kept for pattern matching
    for drive in ${ACTIVE_DRIVES}; do
        IDLE_DRIVES=`sed "s/ ${drive} / /g" <<< ${IDLE_DRIVES}`
    done

    echo ${IDLE_DRIVES}
}

##
# Checks if all not ignored drives are idle.
#
# returns 0 if all drives are idle, 1 if at least one drive is spinning
#
# Arguments:
#   $1 list of idle drives as returned by get_idle_drives()
##
function all_drives_are_idle() {
    local DRIVES=" $(get_drives) "
    
    for drive in ${DRIVES}; do
        if [[ ! $1 =~ $drive ]]; then
            return 1
        fi
    done

    return 0
}

##
# Determines whether the given drive $1 understands ATA commands
#
# Arguments:
#   $1 Device identifier of the drive
##
function is_ata_drive() {
    if [[ ${DRIVES[$1]} == "ATA" ]]; then echo 1; else echo 0; fi
}

##
# Determines whether the given drive $1 is spinning
#
# Arguments:
#   $1 Device identifier of the drive
##
function drive_is_spinning() {
    case $DISK_PARM_TOOL in
        "camcontrol")
            # camcontrol differentiates between ATA and SCSI drives
            if [[ $(is_ata_drive $1) -eq 1 ]]; then
                if [[ -z $(camcontrol epc $1 -c status -P | grep 'Standby') ]]; then echo 1; else echo 0; fi
            else
                # Reads STANDBY values from the power condition mode page (0x1a).
                # THIS IS EXPERIMENTAL AND UNTESTED due to the lack of SCSI drives :(
                #
                # See: /usr/share/misc/scsi_modes and the "SCSI Commands Reference Manual"
                if [[ -z $(camcontrol modepage $1 -m 0x1a |& grep -E "^STANDBY(.*)1") ]]; then echo 1; else echo 0; fi
            fi
        ;;
        "hdparm")
            # It is currently unknown if hdparm also needs to differentiates between ATA and SCSI drives
            if [[ -z $(hdparm -C "/dev/$1" | grep 'standby') ]]; then echo 1; else echo 0; fi
        ;;
    esac
}

##
# Forces the spindown of the drive specified by parameter $1 trough camcontrol
#
# Arguments:
#   $1 Device identifier of the drive
##
function spindown_drive() {
    if [[ $(drive_is_spinning $1) -eq 1 ]]; then
        if [[ $DRYRUN -eq 0 ]]; then
            case $DISK_PARM_TOOL in
                "camcontrol")
                    if [[ $(is_ata_drive $1) -eq 1 ]]; then
                        # Spindown ATA drive
                        camcontrol standby $1
                    else
                        # Spindown SCSI drive
                        camcontrol stop $1
                    fi
                ;;
                "hdparm")
                    hdparm -q -y "/dev/$1"
                ;;
            esac
        fi

        log "$(date '+%F %T') Spun down idle drive: $1"
    else
        log_verbose "$(date '+%F %T') Drive is already spun down: $1"
    fi
}

##
# Generates a list of all active timeouts
##
function get_drive_timeouts() {
    echo -n "$(date '+%F %T') Drive timeouts: "
    for x in "${!DRIVE_TIMEOUTS[@]}"; do printf "[%s]=%s " "$x" "${DRIVE_TIMEOUTS[$x]}" ; done
    echo ""
}

##
# Main program loop
##
function main() {
    if [[ $DRYRUN -eq 1 ]]; then log "Performing a dry run..."; fi

    # Determine disk parameter tool to use
    # (Differentiates between TrueNaS Core and TrueNAs SCALE)
    DISK_PARM_TOOL=$(detect_disk_parm_tool)
    log_verbose "Using disk parameter tool: ${DISK_PARM_TOOL}"

    # Initially identify drives to monitor
    detect_drives
    for drive in ${!DRIVES[@]}; do
        log_verbose "Detected drive ${drive} as ${DRIVES[$drive]} device"
    done

    log "Monitoring drives with a timeout of ${TIMEOUT} seconds: $(get_drives)"
    log "I/O check sample period: ${POLL_TIME} sec"
    
    if [ ${SHUTDOWN_TIMEOUT} -gt 0 ]; then
        log "System will be shut down after ${SHUTDOWN_TIMEOUT} seconds of inactivity"
    fi

    # Init timeout counters for all monitored drives
    declare -A DRIVE_TIMEOUTS
    for drive in $(get_drives); do
        DRIVE_TIMEOUTS[$drive]=${TIMEOUT}
    done
    log_verbose "$(get_drive_timeouts)"
    
    # Init shutdown counter
    SHUTDOWN_COUNTER=${SHUTDOWN_TIMEOUT}

    # Drive I/O monitoring loop
    while true; do
        local IDLE_DRIVES=$(get_idle_drives ${POLL_TIME})

        for drive in "${!DRIVE_TIMEOUTS[@]}"; do
            if [[ $IDLE_DRIVES =~ $drive ]]; then
                DRIVE_TIMEOUTS[$drive]=$((DRIVE_TIMEOUTS[$drive] - POLL_TIME))

                if [[ ! ${DRIVE_TIMEOUTS[$drive]} -gt 0 ]]; then
                    DRIVE_TIMEOUTS[$drive]=${TIMEOUT}
                    spindown_drive ${drive}
                fi
            else
                DRIVE_TIMEOUTS[$drive]=${TIMEOUT}
            fi
        done

        log_verbose "$(get_drive_timeouts)"
        
        if [ ${SHUTDOWN_TIMEOUT} -gt 0 ]; then
            if all_drives_are_idle "${IDLE_DRIVES}"; then
                SHUTDOWN_COUNTER=$((SHUTDOWN_COUNTER - POLL_TIME))
                if [[ ! ${SHUTDOWN_COUNTER} -gt 0 ]]; then
                    log_verbose "Shutting down system"
                    shutdown -p now
                fi
            else
                SHUTDOWN_COUNTER=${SHUTDOWN_TIMEOUT}
            fi
            log_verbose "Shutdown timeout: ${SHUTDOWN_COUNTER}"
        fi

    done
}

# Parse arguments
while getopts ":hqvdmt:p:i:s:" opt; do
  case ${opt} in
    t ) TIMEOUT=${OPTARG}
      ;;
    p ) POLL_TIME=${OPTARG}
      ;;
    i ) IGNORED_DRIVES="$IGNORED_DRIVES ${OPTARG}"
      ;;
    s ) SHUTDOWN_TIMEOUT=${OPTARG}
      ;;
    q ) QUIET=1
      ;;
    v ) VERBOSE=1
      ;;
    d ) DRYRUN=1
      ;;
    m ) MANUAL_MODE=1
      ;;
    h ) print_usage; exit
      ;;
    : ) print_usage; exit
      ;;
    \? ) print_usage; exit
      ;;
  esac
done

main # Start main program
