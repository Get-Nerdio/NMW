#description: Enable Winget for CIS images (UAM) on session host VMs
#execution mode: IndividualWithRestart
#tags: Nerdio
<#
Notes:
This script enables app installers by updating a registry key.

IMPORTANT NOTE: This script is designed to offer a simple method to enabled Winget functionality on a CIS based image or other secure image. 
Please ensure that running this script and enabling Winget does not conflict with your company security policies. If in doubt, DO NOT USE this script. 
Please speak with your security team to establish if this exception may be allowed in your environment.
#>

$WinstationsKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller'
$RegKey = 'EnableAppInstaller'
New-ItemProperty -Path $WinstationsKey -Name $RegKey -PropertyType:dword -Value 1 -Force