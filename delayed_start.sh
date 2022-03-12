#!/usr/bin/env bash

# ##################################################
# Waits until the script file $1 becomes available and starts
# it with the given additional arguments ($2, $3, $4, ...)
#
# See: https://github.com/ngandrass/truenas-spindown-timer
#
#
# MIT License
# 
# Copyright (c) 2022 Niels Gandraß
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

CHECK_INTERVAL=60  # Interval at which to check if script became available

SPINDOWN_TIMER_SCRIPT="$1"; shift
SPINDOWN_TIMER_ARGS="$@"

while true; do
    if [ -f "${SPINDOWN_TIMER_SCRIPT}" ]; then
        ${SPINDOWN_TIMER_SCRIPT} ${SPINDOWN_TIMER_ARGS}
        break
    else
        sleep ${CHECK_INTERVAL}
    fi
done
