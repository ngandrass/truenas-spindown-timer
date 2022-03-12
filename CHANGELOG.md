# Changelog

# Version 1.3.2 (2022-01-10)
  * Include an option to shutdown the system after all monitored drives are idle for a specified number of seconds

# Version 1.3.1 (2019-10-24)
  * Do drive detection at script start to fix erorrs on specific SAS controllers (LSI 9305)

# Version 1.3 (2019-10-09)
  * Introduce manual mode [-m] to disable automatic drive detection
  * Improve script description in print_usage() block
  * Documentation of advanced features and usage

# Version 1.2.1 (2019-09-30)
  * Add info about how to ignore multiple drives to the scripts usage description

# Version 1.2 (2019-07-12)
  * Add experimental support for SCSI drives
  * Use `camcontrol epc` instead of sending raw disk commands during spincheck (Thanks to @bilditup1)

# Version 1.1 (2019-07-09)
  * Add detection of "da" prefixed devices (Thanks to @bilditup1)

# Version 1.0 (2019-07-04)
  * Initial release
