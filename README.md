# Update-UCSFirmware

Script to automate the process of installing UCS firmware updates to VMware hosts.

Connect to vCenter and UCS using Powershell prior to running the script.
Supply information through prompts while running the script or as parameters.

Script will work through hosts sequentially in a specified vCenter cluster, applying updates through Update Manager if desired for drivers and patches.
Host is then shut down and the Host Firmware Package changed to the desired version in UCS and update is started.
Once completed, the host is powered back on. Once it is connected to vCenter, it will be removed from maintenance mode and the next host will begin.