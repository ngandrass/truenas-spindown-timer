#!/bin/bash

TIMEOUT=3600       # Number of seconds to wait for I/O before considering a drive idel
IGNORED_DRIVES=()  # Devices that are never spun down

##
# Retrieves a list of all connected drives (devices prefixed with "ada")
##
get_drives() {
    iostat -x | grep 'ada' | awk '{print $1}'
}

##
# Waits $TIMEOUT seconds and returns a list of all drives that didn't
# experience I/O operations during that period.
#
# Devices listed in $IGNORED_DEVICES will never get returned.
##
get_idle_drives() {
    # Wait for $TIMEOUT seconds and get active drives
    IOSTAT_OUTPUT=`iostat -x -z -d ${TIMEOUT} 2`
    CUT_OFFSET=`grep -no "extended device statistics" <<< ${IOSTAT_OUTPUT} | tail -n1 | grep -Eo '^[^:]+'`
    ACTIVE_DRIVES=`tail -n +$((CUT_OFFSET+2)) <<< ${IOSTAT_OUTPUT} | awk '{printf $1}{printf " "}'`

    # Remove ignored and active drives from list to get idle drives
    IDLE_DRIVES="$(get_drives)"
    for drive in ${IGNORED_DRIVES[@]} ${ACTIVE_DRIVES}; do
        IDLE_DRIVES=`grep -v "${drive}" <<< ${IDLE_DRIVES}`
    done

    echo ${IDLE_DRIVES}
}

##
# Forces the spindown of the drive specified by parameter $1 trough camcontrol
##
spindown_drive() {
    camcontrol standby $1
}


# Main program
for drive in $(get_idle_drives); do
    spindown_drive ${drive}
done
