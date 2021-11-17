# freenas-spindown-timer
_Monitors drive I/O and forces HDD spindown after a given idle period. Resistant to S.M.A.R.T. reads._

Disk spindown has always been an issue for various FreeNAS / TrueNAS users. This
script utilizes `iostat` to detect I/O operations (reads, writes) on each disk.
If a disk didn't receive reads or writes for a given period of time it is
considered idle and gets spun down.

This *excludes* periodic reads of S.M.A.R.T. data performed by the smartctl
service which therefore enables users to have S.M.A.R.T. reporting turned on
while still being able to automatically spin down disks. The script also is
immune to the periodic disk temperature reads in newer versions of FreeNAS /
TrueNAS.

Currently successfully tested on: `TrueNAS-12.0-U6.1 (Core)`, FreeNAS-11.3-U5`,
and `FreeNAS-11.2-U7`.

## Key Features
  * Periodic S.M.A.R.T. reads don't reset the idle timers
  * Configurable idle timeout and poll interval
  * Support for ATA and SCSI devices
  * Per-disk idle timer / Independent spindown
  * Automatic detection or explicit listing of drives to monitor
  * Ignoring of specific drives (e.g. SSD with system dataset)
  * Runnable via `Tasks` as `Post-Init Script`, configurable trough FreeNAS /
    TrueNAS GUI
  * Allows script placement on encrypted pool

## Usage
```
Usage: spindown_timer.sh [-h] [-q] [-v] [-d] [-m] [-t TIMEOUT] [-p POLL_TIME] [-i DRIVE]

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
  -h           : Print this help message.
```

## Deployment and configuration
The following steps describe how to configure FreeNAS / TrueNAS and setup the
script.

### Configure disk standby settings
To prevent the smartctl daemon or TrueNAS from interfering with spun down disks
open the TrueNAS GUI and navigate to `Storage > Disks`.

For every disk that you would like to spin down click the `Edit` button. Then
set the `HDD Standby` option to `Always On` and `Advanced Power Management` to
level 128 or above. 

![HDD standby settings](screenshots/disk-spindown-config.png)

_Note: In older versions of TrueNAS/FreeNAS, it was required to set the
S.M.A.R.T `Power Mode` to `Standby`. This setting was configured globally and
was located under `Services > S.M.A.R.T. > Configure`._

### Deploy script
Copy the script to your NAS and set the execute permission trough `chmod +x spindown_timer.sh`.

That's it! The script can now be run, i.e. in a `tmux` session. However, an automatic start
during FreeNAS's boot sequence is highly recommended (see next section).

### Automatic start at boot
There are multiple ways to enbale the spindown timer after startup. The easiest one probably is
to register it as an `Init Script` within the FreeNAS GUI. This can be done by opening the GUI
and navigating to `Tasks > Init/Shutdown Scripts` and creating a new `Post Init` task that
executes `spindown_timer.sh` after boot.

![Spindown timer post init task](screenshots/task.png)

_Note: Be sure to select `Command` as `Type`_

_Note: With FreeNAS-11.3 a `Timeout` was introduced. However, the spindown script is never
terminated by FreeNAS, regardless of the configured value. Therefore, keep `Timeout` at the
default value of 10 seconds for now._

#### Delayed start (i.e. script placed in encrypted pool)
If you've placed the script at a location that is not available right after boot a delayed start
of the spindown timer is required. This for example applies to situations where the script is
located inside an encrypted pool which needs to be unlocked prior to execution.

To automatically delay the start until the script file becomes available the helper script
`delayed_start.sh` is provided. It takes the full path to the spindown timer script as it's
first argument. Additional arguments are passed to the called script once available. Example
usage: `./delayed_start.sh /mnt/pool/spindown_timer.sh -t 3600 -p 600`

The `delayed_start.sh` script however must again be placed in a location that is available right
after boot. To circumvent this problem you can also use the following one-liner directly from an
`Init/Shutdown Script` as shown in the screenshot below. Set `SCRIPT` to the path where the 
`spindown_timer.sh` file is stored and configure all desired call arguments trough setting them
in the `ARGS` variable. The `CHECK` variable determines the delay between execution attempts in
seconds.

```bash
/bin/bash -c 'SCRIPT="/mnt/pool/spindown_timer.sh"; ARGS="-t 3600 -p 600"; CHECK=60; while true; do if [ -f "${SCRIPT}" ]; then ${SCRIPT} ${ARGS}; break; else sleep ${CHECK}; fi; done'
```

![Spindown timer delayed post init task](screenshots/task-delayed-oneliner.png)

_Note: Be sure to select `Command` as `Type`_

_Note: With FreeNAS-11.3 a `Timeout` was introduced. However, the spindown script is never
terminated by FreeNAS, regardless of the configured value. Therefore, keep `Timeout` at the
default value of 10 seconds for now._

#### Verify autostart
You can verify execution of the script either using a process manager like `htop` or simply by using the following command: `ps -aux | grep "spindown_timer.sh"`

When using a delayed start keep in mind that it might take some seconds before the script availability is updated and the spindown timer is finally executed.

### Verify drive spindown (optional)
It can be useful to check the current power state of a drive. This can be achieved using one of the following commands, depending on your device type.

#### ATA drives
The current power mode of an ATA drive can be checked using the command `camcontrol epc $drive -c status -P`, where `$drive` is the drive to check (e.g. `ada0`).

It should return `Current power state: Standby_z(0x00)` for a spun down drive.

#### SCSI drives
The current power mode of a SCSI drive can be checked trough reading the modepage `0x1a` using the command `camcontrol modepage $drive -m 0x1a`, where `$drive` is the drive to check (e.g. `da0`).

A spun down drive should be in one of the standby states `Standby_y` or `Standby_z`.

A detailed description of the available SCSI modes can be found in `/usr/share/misc/scsi_modes`.

## Advanced usage
In the following section advanced usage scenarios are described.

### Automatic drive detection vs manual mode [-m]
In automatic mode (default) all drives of the system, excluding the ones specified using the `-i` switch, are monitored and spun down if idle.

In scenarios where only a small subset of all avaliable drives should be spun down one can explicitly use the manuel mode trough supplying the `-m` flag. This disables the automatic detection of all drives. Furthermore the `-i` switch is inverted in manual mode. It then can be used to list all drives that should explicitly get monitored and spun down when idle.

An example in which only the drives `ada3` and `ada6` are monitored would look like this:
```bash
./spindown_timer.sh -m -i ada3 -i ada6
```

It is also possible to run multiple instances of the script with independent `TIMEOUT` values for different drives. In the following example all drives expect `ada0` and `ada1` are spun down after being idle for 3600 seconds where `ada0` and `ada1` are already spun down after 600 seconds of being considered as idle:
```bash
./spindown_timer.sh -t 3600 -i ada0 -i ada1    # Automatic drive detection
./spindown_timer.sh -m -t 600 -i ada0 -i ada1  # Manual mode
```

To verify the correct drive selection, a list of all drives that are being monitored by the running script instance is printed directly after starting the script (except in quiet mode [-q]).

## Warning
Heavily spinning disk drives up and down increases disk wear. Before deploying this script, consider carefully which of your drives are frequently accessed and should therefore not be aggressively spun down. A good rule of thumb is to keep disk spin-ups below 5 per 24 hours. You can keep an eye on your drives `Load_Cycle_Count` and `Start_Stop_Count` S.M.A.R.T values to monitor the number of performed spin-ups.

**Please do not spin down your drives in an enterprise environment. Only consider using this technique with small NAS setups which idle most time of the day and select a timeout value appropriate to your usage behavior.**

Another useful scenario i.e. is spinning down drives that are only used once a day (e.g. for mirroring of files or backups).

## Bug reports and contributions
Bug report and contributions are welcome! Feel free to open a new issue or submit a merge request :)

## Attributions
The script is heavily inspired by: [https://serverfault.com/a/969252](https://serverfault.com/a/969252)

## Support
My work helped you in some way or you just like it? Awesome!

If you want to support me you can consider buying me a cofee/tea/mate. Thank You! <3

<a href="https://paypal.me/ngandrass">
  <img src="https://raw.githubusercontent.com/stefan-niedermann/paypal-donate-button/master/paypal-donate-button.png" width="220px" alt="Donate with PayPal" />
</a>

[![ko-fi.com/ngandrass](https://www.ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/A0A3XX87)
