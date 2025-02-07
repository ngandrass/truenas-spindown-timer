#!/usr/bin/env bash

# ##################################################
# TrueNAS HDD Spindown Timer
# Monitors drive I/O and forces HDD spindown after a given idle period.
#
# Version: 2.3.0
#
# See: https://github.com/ngandrass/truenas-spindown-timer
#
#
# MIT License
# 
# Copyright (c) 2025 Niels Gandraß <niels@gandrass.de>
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

VERSION=2.3.0
TIMEOUT=3600                                # Default timeout before considering a drive as idle
POLL_TIME=600                               # Default time to wait during a single iostat call
IGNORED_DRIVES=""                           # Default list of drives that are never spun down
MANUAL_MODE=0                               # Default manual mode setting
ONESHOT_MODE=0                              # Default for one shot mode setting
CHECK_MODE=0                                # Default check mode setting
QUIET=0                                     # Default quiet mode setting
VERBOSE=0                                   # Default verbosity level
LOG_TO_SYSLOG=0                             # Default for logging target (stdout/stderr or syslog)
DRYRUN=0                                    # Default for dryrun option
SHUTDOWN_TIMEOUT=0                          # Default shutdown timeout (0 == no shutdown)
declare -A DRIVES                           # Associative array for detected drives
declare -A ZFSPOOLS                         # Array for monitored ZFS pools
declare -A DRIVES_BY_POOLS                  # Associative array mapping of pool names to list of disk identifiers (e.g. poolname => "ada0 ada1 ada2")
declare -A DRIVEID_TO_DEV                   # Associative array with the drive id (e.g. GPTID) to a device identifier
HOST_PLATFORM=                              # Detected type of the host os (FreeBSD for TrueNAS CORE or Linux for TrueNAS SCALE)
DRIVEID_TYPE=                               # Default for type used for drive IDs ('gptid' (CORE) or 'partuuid' (SCALE))
OPERATION_MODE=disk                         # Default operation mode (disk or zpool)
DISK_CTRL_TOOL=                             # Disk control tool to use (camcontrol, hdparm, or smartctl)

##
# Prints the help/usage message
##
function print_usage() {
    cat << EOF
Usage:
  $0 [-h] [-q] [-v] [-l] [-d] [-o] [-c] [-m] [-u <MODE>] [-t <TIMEOUT>] [-p <POLL_TIME>] [-i <DRIVE>] [-s <TIMEOUT>] [-x <TOOL>]

Monitors drive I/O and forces HDD spindown after a given idle period.
Resistant to S.M.A.R.T. reads.

Operation is supported on either drive level (MODE = disk) with plain device
identifiers or zpool level (MODE = zpool) with zfs pool names. See -u for more
information. A drive is considered idle and gets spun down if there has been no
I/O operations on it for at least TIMEOUT seconds. I/O requests are detected
within multiple intervals with a length of POLL_TIME seconds. Detected reads or
writes reset the drives timer back to TIMEOUT.

Options:
  -t TIMEOUT   : Total spindown delay. Number of seconds a drive has to
                 experience no I/O activity before it is spun down (default: 3600).
  -p POLL_TIME : I/O poll interval. Number of seconds to wait for I/O during a
                 single monitoring period (default: 600).
  -s TIMEOUT   : Shutdown timeout. If given and no drive is active for TIMEOUT
                 seconds, the system will be shut down.
  -u MODE      : Operation mode (default: disk).
                 If set to 'disk', the script operates with disk identifiers
                 (e.g. ada0) for all CLI arguments and monitors I/O using
                 iostat directly.
                 If set to 'zpool' the script operates with ZFS pool names
                 (e.g. zfsdata) for all CLI arguments and monitors I/O using
                 the iostat of zpool.
  -i DRIVE     : In automatic drive detection mode (default):
                   Ignores the given drive or zfs pool.
                 In manual mode [-m]:
                   Only monitor the specified drives or zfs pools. Multiple
                   drives or zfs pools can be given by repeating the -i option.
  -m           : Manual drive detection mode. If set, automatic drive detection
                 is disabled.
                 CAUTION: This inverts the -i option, which can then be used to
                 manually supply drives or zfs pools to monitor. All other drives
                 or zfs pools will be ignored.
  -o           : One shot mode. If set, the script performs exactly one I/O poll
                 interval, then immediately spins down drives that were idle for
                 the last <POLL_TIME> seconds, and exits. This option ignores
                 <TIMEOUT>. It can be useful, if you want to invoke to script
                 via cron.
  -c           : Check mode. Outputs drive power state after each POLL_TIME
                 seconds.
  -q           : Quiet mode. Outputs are suppressed set.
  -v           : Verbose mode. Prints additional information during execution.
  -l           : Syslog logging. If set, all output is logged to syslog instead
                 of stdout/stderr.
  -d           : Dry run. No actual spindown is performed.
  -h           : Print this help message.
  -x TOOL      : Forces use of a specifiy tool for disk control.
                 Supported tools are: "camcontrol", "hdparm", and "smartctl".
                 If not specified, the first available tool (from left to right)
                 will be automatically selected.

Example usage:
$0
$0 -q -t 3600 -p 600 -i ada0 -i ada1
$0 -q -m -i ada6 -i ada7 -i da0
$0 -u zpool -i freenas-boot
EOF
}

##
# Writes argument $1 to stdout/syslog if $QUIET is not set
#
# Arguments:
#   $1 Message to write to stdout/syslog
##
function log() {
    if [[ $QUIET -eq 0 ]]; then
        if [[ $LOG_TO_SYSLOG -eq 1 ]]; then
            echo "$1" | logger -i -t "spindown_timer"
        else
            echo "[$(date '+%F %T')] $1"
        fi
    fi
}

##
# Writes argument $1 to stdout/syslog if $VERBOSE is set and $QUIET is not set
#
# Arguments:
#   $1 Message to write to stdout/syslog
##
function log_verbose() {
    if [[ $VERBOSE -eq 1 ]]; then
        log "$1"
    fi
}

##
# Writes argument $1 to stderr/syslog. Ignores $QUIET.
#
# Arguments:
#   $1 Message to write to stderr/syslog
##
function log_error() {
    if [[ $LOG_TO_SYSLOG -eq 1 ]]; then
        echo "[ERROR]: $1" | logger -i -t "spindown_timer"
    else
        >&2 echo "[$(date '+%F %T')] [ERROR]: $1"
    fi
}

##
# Detects the host platform (FreeBSD (TrueNAS CORE) or Linux (TrueNAS SCALE))
##
function detect_host_platform() {
    if [[ "$(uname)" == "Linux" ]]; then
        HOST_PLATFORM=Linux
    elif [[ "$(uname)" == "FreeBSD" ]]; then
        HOST_PLATFORM=FreeBSD
    else
        log_error "Unsupported host OS type: $(uname). Assuming Linux for now ..."
        HOST_PLATFORM=Linux
        return
    fi

    log_verbose "Detected host OS type: $HOST_PLATFORM"
}

##
# Determines which tool to control disks is available. This
# differentiates between TrueNAS Core and TrueNAS SCALE.
#
# Return: Command to use to control disks
#
##
detect_disk_ctrl_tool() {
    local SUPPORTED_DISK_CTRL_TOOLS
    SUPPORTED_DISK_CTRL_TOOLS=("camcontrol" "hdparm" "smartctl")

    # If a specific tool is given by the user (via -x), validate it
    if [[ " ${SUPPORTED_DISK_CTRL_TOOLS[@]} " =~ " ${DISK_CTRL_TOOL} " ]]; then
        # Check if the tool is available on the system
        if which "$DISK_CTRL_TOOL" &> /dev/null; then
            echo "$DISK_CTRL_TOOL"
            return
        else
            log_error "$DISK_CTRL_TOOL is not installed or not found."
            return
        fi
    fi

    # Do not perform autodetect if user explicit specified a tool that is not available
    if [[ -n $DISK_CTRL_TOOL ]]; then
        log_error "Unsupported disk control tool: $DISK_CTRL_TOOL"
        return
    fi

    # Auto-detect available tools if no specific tool was given by the user
    for tool in "${SUPPORTED_DISK_CTRL_TOOLS[@]}"; do
        if which "$tool" &> /dev/null; then
            # Return the first available tool
            echo "$tool"
            return
        fi
    done

    log_error "No supported disk control tool found."
    return
}

##
# Detects which type of drive IDs are used.
# CORE uses glabel GPTIDs, SCALE uses partuuids
##
function detect_driveid_type() {
    if [[ -n $(which glabel) ]]; then
        DRIVEID_TYPE=gptid
    elif [[ -d "/dev/disk/by-partuuid/" ]]; then
        DRIVEID_TYPE=partuuid
    else
        log_error "Cannot detect drive id type. Exiting..."
        exit 1
    fi

    log_verbose "Detected drive id type: $DRIVEID_TYPE"
}

##
# Populates the DRIVEID_TO_DEV associative array. Drive IDs are used as keys.
# Must be called after detect_driveid_type()
#
function populate_driveid_to_dev_array() {
    # Create mapping
    case $DRIVEID_TYPE in
        "gptid")
            # glabel present. Index by GPTID (CORE)
            log_verbose "Creating disk to dev mapping using: glabel"
            while read -r row; do
                local gptid=$(echo "$row" | cut -d ' ' -f1)
                local diskid=$(echo "$row" | cut -d ' ' -f3 | rev | cut -d 'p' -f2 | rev)

                if [[ "$gptid" = "gptid"* ]]; then
                    DRIVEID_TO_DEV[$gptid]=$diskid
                fi
            done < <(glabel status | tail -n +2 | tr -s ' ')
        ;;
        "partuuid")
            # glabel absent. Try to detect by partuuid (SCALE)
            log_verbose "Creating disk to dev mapping using: partuuid"
            while read -r row; do
                local partuuid=$(basename -- "${row}")
                local dev=$(basename -- "$(readlink -f "${row}")" | sed "s/[0-9]\+$//")
                DRIVEID_TO_DEV[$partuuid]=$dev
            done < <(find /dev/disk/by-partuuid/ -type l)
        ;;
    esac

    # Verbose logging
    if [ $VERBOSE -eq 1 ]; then
        log_verbose "Detected disk identifier to dev mappings:"
        for deviceid in "${!DRIVEID_TO_DEV[@]}"; do
            log_verbose "-> [$deviceid]=${DRIVEID_TO_DEV[$deviceid]}"
        done
    fi
}

##
# Registers a new drive in $DRIVES array and detects if it is an ATA or SCSI
# drive.
#
# Arguemnts:
#   $1 Device identifier (e.g. ada0)
##
function register_drive() {
    local drive="$1"
    if [ -z "$drive" ]; then
        log_error "Failed to register drive. Empty name received."
        return 1
    fi

    local DISK_IS_ATA
    case $DISK_CTRL_TOOL in
        "camcontrol") DISK_IS_ATA=$(camcontrol identify $drive |& grep -E "^protocol(.*)ATA");;
        "hdparm") DISK_IS_ATA=$(hdparm -I "/dev/$drive" |& grep -E "^ATA device");;
        "smartctl") DISK_IS_ATA=$(smartctl -i "/dev/$drive" |& grep -E "ATA V");;
    esac

    if [[ -n $DISK_IS_ATA ]]; then
        DRIVES[$drive]="ATA"
    else
        DRIVES[$drive]="SCSI"
    fi
}

##
# Detects all connected drives using plain iostat method and whether they are
# ATA or SCSI drives. Drives listed in $IGNORE_DRIVES will be excluded.
#
# Note: This function populates the $DRIVES array directly.
##
function detect_drives_disk() {
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
    for drive in ${DRIVE_IDS}; do
        register_drive "$drive"
    done
}

##
# Detects all connected drives using zpool list method and whether they are
# ATA or SCSI drives. Drives listed in $IGNORE_DRIVES will be excluded.
#
# Note: This function populates the $DRIVES array directly.
##
function detect_drives_zpool() {
    local DRIVE_IDS

    # Detect zfs pools
    if [[ $MANUAL_MODE -eq 1 ]]; then
        # Only use explicitly supplied pool names
        for poolname in $IGNORED_DRIVES; do
            ZFSPOOLS[${#ZFSPOOLS[@]}]="$poolname"
            log_verbose "Using zfs pool: $poolname"
        done
    else
        # Auto detect available pools
        local poolnames=$(zpool list -H -o name)

        # Remove ignored pools
        for ignored_pool in $IGNORED_DRIVES; do
            poolnames=${poolnames//$ignored_pool/}
            log_verbose "Ignoring zfs pool: $ignored_pool"
        done

        # Store remaining detected pools
        for poolname in $poolnames; do
            ZFSPOOLS[${#ZFSPOOLS[@]}]="$poolname"
            log_verbose "Detected zfs pool: $poolname"
        done
    fi

    # Index disks in detected pools
    for poolname in ${ZFSPOOLS[*]}; do
        local disks
        if ! disks=$(zpool list -H -v "$poolname"); then
            log_error "Failed to get information for zfs pool: $poolname. Are you sure it exists?"
            continue;
        fi

        log_verbose "Detecting disks in pool: $poolname"

        while read -r driveid; do
            # Remove invalid rows (Cannot be statically cut because of different pool geometries)
            case $DRIVEID_TYPE in
                "gptid")    driveid=$(echo "$driveid" | grep -E "^gptid/.*$" | sed "s/^\(.*\)\.eli$/\1/") ;;
                "partuuid") driveid=$(echo "$driveid" | grep -E "^(\w+\-){2,}") ;;
            esac

            # Skip if current row is invalid after filtering above
            if [ -z "$driveid" ]; then
                continue
            fi

            # Skip nvme drives
            if [[ "${DRIVEID_TO_DEV[$driveid]}" == "nvme"* ]]; then
                log_verbose "-> Skipping NVMe drive: $driveid"
                continue
            fi

            log_verbose "-> Detected disk in pool $poolname: ${DRIVEID_TO_DEV[$driveid]} ($driveid)"
            register_drive "${DRIVEID_TO_DEV[$driveid]}"
            DRIVES_BY_POOLS[$poolname]="${DRIVES_BY_POOLS[$poolname]} ${DRIVEID_TO_DEV[$driveid]}"
        done < <(echo "$disks" | tr -s "\\t" " " | cut -d ' ' -f2)
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
    local IOSTAT_OUTPUT
    local ACTIVE_DRIVES
    case $OPERATION_MODE in
        "disk")
            # Operation mode: disk. Detect IO using iostat
            IOSTAT_OUTPUT=$(iostat -x -z -d $1 2)
            case $HOST_PLATFORM in
                "FreeBSD")
                    local CUT_OFFSET=$(grep -no "extended device statistics" <<< "$IOSTAT_OUTPUT" | tail -n1 | cut -d: -f1)
                    CUT_OFFSET=$((CUT_OFFSET+2))
                    ;;
                "Linux")
                    local CUT_OFFSET=$(grep -no "Device" <<< "$IOSTAT_OUTPUT" | tail -n1 | cut -d: -f1)
                    CUT_OFFSET=$((CUT_OFFSET+1))
                    ;;
            esac
            ACTIVE_DRIVES=$(sed -n "${CUT_OFFSET},\$p" <<< "$IOSTAT_OUTPUT" | cut -d' ' -f1 | tr '\n' ' ')
            log_verbose "-> Active Drive(s): $ACTIVE_DRIVES" >&2
        ;;
        "zpool")
            # Operation mode: zpool. Detect IO using zpool iostat
            IOSTAT_OUTPUT=$(zpool iostat -H ${ZFSPOOLS[*]} $1 2)

            while read -r row; do
                local poolname=$(echo "$row" | cut -d ' ' -f1)
                local reads=$(echo "$row" | cut -d ' ' -f4)
                local writes=$(echo "$row" | cut -d ' ' -f5)

                if [ "$reads" != "0" ] || [ "$writes" != "0" ]; then
                    ACTIVE_DRIVES="$ACTIVE_DRIVES ${DRIVES_BY_POOLS[$poolname]}"
                fi
            done < <(tail -n +$((${#ZFSPOOLS[@]}+1)) <<< "${IOSTAT_OUTPUT}" | tr -s "\\t" " ")
        ;;
    esac

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
    case $DISK_CTRL_TOOL in
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
        "smartctl")
            if [[ -z $(smartctl --nocheck standby -i "/dev/$1" | grep -q 'Device is in STANDBY mode') ]]; then echo 1; else echo 0; fi
        ;;
    esac
}

##
# Determines if all monitored drives are currently spun down
##
function all_monitored_drives_are_spun_down() {
    for drive in "${!DRIVE_TIMEOUTS[@]}"; do
        if [[ $(drive_is_spinning "$drive") -eq 1 ]]; then
            echo 0
            return
        fi
    done

    echo 1
    return
}

##
# Prints the power state of all monitored drives
##
function print_drive_power_states() {
    local powerstates=""

    for drive in $(get_drives); do
        powerstates="${powerstates} [$drive] => $(drive_is_spinning "$drive")"
    done

    log "Drive power states: ${powerstates:1}"
}

##
# Forces the spindown of the drive specified by parameter $1
#
# Arguments:
#   $1 Device identifier of the drive
##
function spindown_drive() {
    if [[ $(drive_is_spinning $1) -eq 1 ]]; then
        if [[ $DRYRUN -eq 0 ]]; then
            case $DISK_CTRL_TOOL in
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
                "smartctl")
                    smartctl --set=standby,now "/dev/$1"
                ;;
            esac

            log "Spun down idle drive: $1"
        else
            log "Would spin down idle drive: $1. No spindown was performed (dry run)."
        fi
    else
        log_verbose "Drive is already spun down: $1"
    fi
}

##
# Generates a list of all active timeouts
##
function get_drive_timeouts() {
    echo -n "Drive timeouts: "
    for x in "${!DRIVE_TIMEOUTS[@]}"; do printf "[%s]=%s " "$x" "${DRIVE_TIMEOUTS[$x]}" ; done
    echo ""
}

##
# Main program loop
##
function main() {
    log_verbose "Running HDD Spindown Timer version $VERSION"
    if [[ $DRYRUN -eq 1 ]]; then log "Performing a dry run..."; fi

    # Detect host platform and user
    detect_host_platform
    log_verbose "Running as user: $(whoami) (UID: $(id -u))"

    # Setup one shot mode, if selected
    if [[ $ONESHOT_MODE -eq 1 ]]; then
        TIMEOUT=$POLL_TIME
        log "Running in one shot mode... Notice: Timeout (-t) value will be ignored. Using poll time (-p) instead.";
    fi

    # Verify operation mode
    if [ "$OPERATION_MODE" != "disk" ] && [ "$OPERATION_MODE" != "zpool" ]; then
        log_error "Invalid operation mode: $OPERATION_MODE. Must be either 'disk' or 'zpool'."
        exit 1
    fi
    log_verbose "Operation mode: $OPERATION_MODE"

    # Determine disk control tool to use
    # (Differentiates between TrueNaS Core and TrueNAs SCALE)
    DISK_CTRL_TOOL=$(detect_disk_ctrl_tool)
    if [[ -z $DISK_CTRL_TOOL ]]; then
        log_error "No applicable control tool found. Exiting..."
        exit 1
    fi
    log_verbose "Using disk control tool: ${DISK_CTRL_TOOL}"

    # Initially identify drives to monitor
    detect_driveid_type
    populate_driveid_to_dev_array
    detect_drives_$OPERATION_MODE

    if [[ ${#DRIVES[@]} -eq 0 ]]; then
        log_error "No drives to monitor detected. Exiting..."
        exit 1
    fi

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
        if [ $CHECK_MODE -eq 1 ]; then
            print_drive_power_states
        fi

        if [[ $(all_monitored_drives_are_spun_down) -eq 1 ]]; then
            log_verbose "All monitored drives are already spun down, sleeping ${TIMEOUT} seconds ..."
            sleep ${TIMEOUT}
            continue
        fi

        local IDLE_DRIVES=$(get_idle_drives ${POLL_TIME})

        # Update drive timeouts and spin down idle drives
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

        # Handle shutdown timeout
        if [ ${SHUTDOWN_TIMEOUT} -gt 0 ]; then
            if all_drives_are_idle "${IDLE_DRIVES}"; then
                SHUTDOWN_COUNTER=$((SHUTDOWN_COUNTER - POLL_TIME))
                if [[ ! ${SHUTDOWN_COUNTER} -gt 0 ]]; then
                    log_verbose "Shutting down system"
                    case $HOST_PLATFORM in
                        "FreeBSD") shutdown -p now ;;
                        *) shutdown -h now ;;
                    esac
                fi
            else
                SHUTDOWN_COUNTER=${SHUTDOWN_TIMEOUT}
            fi
            log_verbose "Shutdown timeout: ${SHUTDOWN_COUNTER}"
        fi

        # Handle one shot mode
        if [[ $ONESHOT_MODE -eq 1 ]]; then
            log_verbose "One shot mode: Exiting..."
            exit 0
        fi

        # Log updated drive timeouts
        log_verbose "$(get_drive_timeouts)"
    done
}

# Parse arguments
while getopts ":hqvdlmoct:p:i:s:u:x:" opt; do
  case ${opt} in
    t ) TIMEOUT=${OPTARG}
      ;;
    p ) POLL_TIME=${OPTARG}
      ;;
    i ) IGNORED_DRIVES="$IGNORED_DRIVES ${OPTARG}"
      ;;
    s ) SHUTDOWN_TIMEOUT=${OPTARG}
      ;;
    o ) ONESHOT_MODE=1
      ;;
    c ) CHECK_MODE=1
      ;;
    q ) QUIET=1
      ;;
    v ) VERBOSE=1
      ;;
    l ) LOG_TO_SYSLOG=1
      ;;
    d ) DRYRUN=1
      ;;
    m ) MANUAL_MODE=1
      ;;
    u ) OPERATION_MODE=${OPTARG}
      ;;
    x ) DISK_CTRL_TOOL=${OPTARG}
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
