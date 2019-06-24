# freenas-spindown-timer
_Monitors drive I/O and forces HDD spindown after a given idle period. Resistant to S.M.A.R.T. reads._

Disk spindown has always been an issue for various FreeNAS users. This script utilizes `iostat` to
detect I/O operations (reads, writes) on each disk. If a disk didn't receive reads or writes for a
given period of time it is considered idle and gets spun down.

This *excludes* periodic reads of S.M.A.R.T. data performed by the smartctl service which
therefore enables users to have S.M.A.R.T. reporting turned on while still being able to
automatically spin down disks. The script is also immune to the periodic disk temperature
reads in newer versions of FreeNAS.

Currently tested on `FreeNAS-11.2-U4.1`.

## Key Features
  * Periodic S.M.A.R.T. reads don't reset the idle timers
  * Configurable idle timeout and poll interval
  * Per-disk idle timer / Independent spindown
  * Ignoring of specific drives (e.g. SSD with system dataset)
  * Runnable via `Tasks` as `Post-Init Script`, configurable trough FreeNAS GUI
  * Allows script placement on encrypted pool

## Usage
```
Usage: spindown_timer.sh [-h] [-q] [-v] [-d] [-t TIMEOUT] [-p POLL_TIME] [-i DRIVE]

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
  -h           : Print this help message.
```

## Deployment and configuration
// TODO

## Bug reports and contributions
Bug report and contributions are welcome! Feel free to open a new issue or submit a merge request :)

## Attributions
The script is heavily inspired by: [https://serverfault.com/a/969252](https://serverfault.com/a/969252)
