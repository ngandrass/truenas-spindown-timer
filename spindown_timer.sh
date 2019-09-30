#!/usr/bin/env bash

# ##################################################
# FreeNAS HDD Spindown Timer
# Monitors drive I/O and forces HDD spindown after a given idle period.
#
# Version: 1.2
#
# See: https://github.com/ngandrass/freenas-spindown-timer
#
#
# MIT License
# 
# Copyright (c) 2019 Niels Gandraß
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

TIMEOUT=3600       # Default timeout before considering a drive as idle
POLL_TIME=600      # Default time to wait during a single iostat call
IGNORED_DRIVES=""  # Default list of drives that are never spun down
QUIET=0            # Default quiet mode setting
VERBOSE=0          # Default verbosity level
DRYRUN=0           # Default for dryrun option

##
# Prints the help/usage message
##
function print_usage() {
    cat << EOF
Usage: $0 [-h] [-q] [-v] [-d] [-t TIMEOUT] [-p POLL_TIME] [-i DRIVE]

A drive is considered as idle and is spun down if there has been no I/O
operations on it for at least TIMEOUT seconds. I/O requests are detected
during intervals with a length of POLL_TIME seconds. Detected reads or
writes reset the drives timer back to TIMEOUT.

Options:
  -q           : Quiet mode. Outputs are suppressed if flag is present.
  -v           : Verbose mode. Prints additonal information during execution.
  -d           : Dry run. No actual spindown is performed.
  -t TIMEOUT   : Number of seconds to wait for I/O in total before considering
                 a drive as idle.
  -p POLL_TIME : Number of seconds to wait for I/O during a single iostat call.
  -i DRIVE     : Ignores the given drive and never issue a spindown for it.
                 Multiple drives can be ignores by repeating the -i switch.
  -h           : Print this help message.

Example usage:
$0
$0 -q -t 3600 -p 600 -i ada0 -i ada1
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
# Retrieves a list of all connected drives (devices prefixed with "ada|da").
#
# Drives listed in $IGNORE_DRIVES will be excluded.
##
function get_drives() {
    local DRIVES=`iostat -x | grep -E '^(ada|da)' | awk '{printf $1 " "}'`
    DRIVES=" ${DRIVES} " # Space padding must be kept for pattern matching

    # Remove ignored drives
    for drive in ${IGNORED_DRIVES[@]}; do
        DRIVES=`sed "s/ ${drive} / /g" <<< ${DRIVES}`
    done

    echo ${DRIVES}
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
    local CUT_OFFSET=`grep -no "extended device statistics" <<< ${IOSTAT_OUTPUT} | tail -n1 | grep -Eo '^[^:]+'`
    local ACTIVE_DRIVES=`tail -n +$((CUT_OFFSET+2)) <<< ${IOSTAT_OUTPUT} | awk '{printf $1}{printf " "}'`

    # Remove active drives from list to get idle drives
    local IDLE_DRIVES=" $(get_drives) " # Space padding must be kept for pattern matching
    for drive in ${ACTIVE_DRIVES}; do
        IDLE_DRIVES=`sed "s/ ${drive} / /g" <<< ${IDLE_DRIVES}`
    done

    echo ${IDLE_DRIVES}
}

##
# Determines whether the given drive $1 understands ATA commands
#
# Arguments:
#   $1 Device identifier of the drive
##
function is_ata_drive() {
    if [[ -n $(camcontrol identify $1 |& grep -E "^protocol(.*)ATA") ]]; then echo 1; else echo 0; fi
}

##
# Determines whether the given drive $1 is spinning
#
# Arguments:
#   $1 Device identifier of the drive
##
function drive_is_spinning() {
    if [[ $(is_ata_drive $1) -eq 1 ]]; then
        if [[ -z $(camcontrol epc $1 -c status -P | grep 'Standby') ]]; then echo 1; else echo 0; fi
    else
        # Reads STANDBY values from the power condition mode page (0x1a).
        # THIS IS EXPERIMENTAL AND UNTESTED due to the lack of SCSI drives :(
        #
        # See: /usr/share/misc/scsi_modes and the "SCSI Commands Reference Manual"
        if [[ -z $(camcontrol modepage $1 -m 0x1a |& grep -E "^STANDBY(.*)1") ]]; then echo 1; else echo 0; fi
    fi
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
            if [[ $(is_ata_drive $1) -eq 1 ]]; then
                # Spindown ATA drive
                camcontrol standby $1
            else
                # Spindown SCSI drive
                camcontrol stop $1
            fi
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

    log "Monitoring drives with a timeout of ${TIMEOUT} seconds: $(get_drives)"
    log "I/O check sample period: ${POLL_TIME} sec"

    # Init timeout counters for all monitored drives
    declare -A DRIVE_TIMEOUTS
    for drive in $(get_drives); do
        DRIVE_TIMEOUTS[$drive]=${TIMEOUT}
    done
    log_verbose "$(get_drive_timeouts)"

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
    done
}

# Parse arguments
while getopts ":hqvdt:p:i:" opt; do
  case ${opt} in
    t ) TIMEOUT=${OPTARG}
      ;;
    p ) POLL_TIME=${OPTARG}
      ;;
    i ) IGNORED_DRIVES="$IGNORED_DRIVES ${OPTARG}"
      ;;
    q ) QUIET=1
      ;;
    v ) VERBOSE=1
      ;;
    d ) DRYRUN=1
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
