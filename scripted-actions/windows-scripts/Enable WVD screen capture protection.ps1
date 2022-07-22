#description: Enables screen capture protection on AVD session host VMs
#execution mode: IndividualWithRestart
#tags: Nerdio
<#
Notes:
This script enables screen captutre protection by adding a registry key.
For more infromation, please refer to MS Documentation on this feature:
https://docs.microsoft.com/en-us/azure/virtual-desktop/security-guide#enable-screen-capture-protection-preview
#>

reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" /v fEnableScreenCaptureProtect /t REG_DWORD /d 1 /f
