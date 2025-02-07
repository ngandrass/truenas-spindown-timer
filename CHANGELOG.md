# Changelog

## Version X.Y.Z (YYYY-MM-DD)
  * Fix shutdown mode on TrueNAS SCALE
  * Improve host system detection to distinguish between TrueNAS CORE and TrueNAS SCALE
  * Simplify active drive detection
  * Skip drive I/O detection loop if all monitored drives are already sleeping
  * Add support for using `smartctl` to interact with drives
  * Allow selection of disk control tool (`camcontrol`, `hdparm`, `smartctl`) via CLI argument `-x`


## Version 2.3.0 (2024-08-26)
  * Introduce syslog mode (`-l`). If set, all output is logged to syslog instead of stdout/stderr.
  * Introduce one shot mode (`-o`). If set, the script performs exactly one I/O poll interval, then immediately spins down drives that were idle for the last `POLL_TIME` seconds, and exits.
  * Skip NVMe drives during drive detection.
  * Exit with an error, if no drives were found during drive detection.


## Version 2.2.0 (2023-02-20)
  * Introduce the check mode (`-c`) to display the current power mode of all monitored drives every `POLL_TIME` seconds. See [README.md > Using the check mode](https://github.com/ngandrass/truenas-spindown-timer#automatic-using-the-check-mode--c) for more details.


## Version 2.1.0 (2023-02-19)
  * New CLI argument to switch between `disk` and `zpool` operation mode: `-u <MODE>`
    * When no operation mode is explicitly given, the script works in `disk` mode. This completely ignores zfs pools and works as before.
    * When operation mode is set to `zpool` by supplying `-u zpool`, the script now operates on a per-zpool basis. I/O is monitored for the pool as a whole and disks are only spun down if the complete pool was idle for a given number of seconds. ZFS pools are either detected automatically or can be supplied manually (see help text for `-i` and `-m`).
    * Drives are referenced by GPTID (CORE) or partuuid (SCALE) in ZFS pool mode.


## Version 2.0.1 (2022-09-17)
  * Added support for TrueNAS SCALE using `hdparm` instead of `camcontrol`. The script automatically detects the environment it is run in.


## Version 1.3.2 (2022-01-10)
  * Include an option to shutdown the system after all monitored drives are idle for a specified number of seconds


## Version 1.3.1 (2019-10-24)
  * Do drive detection at script start to fix erorrs on specific SAS controllers (LSI 9305)


## Version 1.3.0 (2019-10-09)
  * Introduce manual mode [-m] to disable automatic drive detection
  * Improve script description in print_usage() block
  * Documentation of advanced features and usage


## Version 1.2.1 (2019-09-30)
  * Add info about how to ignore multiple drives to the scripts usage description


## Version 1.2.0 (2019-07-12)
  * Add experimental support for SCSI drives
  * Use `camcontrol epc` instead of sending raw disk commands during spincheck (Thanks to @bilditup1)


## Version 1.1.0 (2019-07-09)
  * Add detection of "da" prefixed devices (Thanks to @bilditup1)


## Version 1.0.0 (2019-07-04)
  * Initial release
