#description: Enable RDP Shortpath for public networks on session host VMs
#execution mode: IndividualWithRestart
#tags: Nerdio, Preview
<#
Notes:
This script will setup windows OS for RDP shortpath for public networks as defined here: 
https://docs.microsoft.com/en-us/azure/virtual-desktop/shortpath-public

This feature is in preview, and it is recommended that you test in a validation environment
before using in production.

A reboot is required after running this script for the configuration to take effect.
#>

# Add registry keys

REG ADD "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations" /v ICEControl /t REG_DWORD  /d 2 /f