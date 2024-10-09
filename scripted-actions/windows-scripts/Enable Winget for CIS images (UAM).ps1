#description: Enable Winget for CIS images (UAM) on session host VMs
#execution mode: IndividualWithRestart
#tags: Nerdio
<#
Notes:
This script enables app installers by updating a registry key.
#>

$WinstationsKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller'
$RegKey = 'EnableAppInstaller'
New-ItemProperty -Path $WinstationsKey -Name $RegKey -PropertyType:dword -Value 1 -Force