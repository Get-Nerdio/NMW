#description: Downloads and installs Zoom VDI client for WVD. Reference https://support.zoom.us/hc/en-us/articles/360052984292 (under "Windows Virtual Desktop") for more information
#execution mode: IndividualWithRestart
#tags: Nerdio, Apps install
<# 
Notes:
This script installs the Zoom VDI client for use on WVD Session hosts.

To install specific versions, update the URL variables below with links to the .msi installers.
#>

$ZoomClientUrl= "https://zoom.us/download/vdi/5.12.6.22200/ZoomInstallerVDI.msi"

# Start powershell logging
$SaveVerbosePreference = $VerbosePreference
$VerbosePreference = 'continue'
$VMTime = Get-Date
$LogTime = $VMTime.ToUniversalTime()
mkdir "C:\Windows\temp\NerdioManagerLogs\ScriptedActions\zoom_sa" -Force
Start-Transcript -Path "C:\Windows\temp\NerdioManagerLogs\ScriptedActions\zoom_sa\ps_log.txt" -Append
Write-Host "################# New Script Run #################"
Write-host "Current time (UTC-0): $LogTime"

# Make directory to hold install files
mkdir "C:\Windows\Temp\zoom_sa\install" -Force

Invoke-WebRequest -Uri $ZoomClientUrl -OutFile "C:\Windows\Temp\zoom_sa\install\ZoomInstallerVDI.msi" -UseBasicParsing

# Install Zoom. Edit the argument list as desired for customized installs: https://support.zoom.us/hc/en-us/articles/201362163
Write-Host "INFO: Installing Zoom client. . ."
Start-Process C:\Windows\System32\msiexec.exe `
-ArgumentList "/i C:\Windows\Temp\zoom_sa\install\ZoomInstallerVDI.msi /l*v C:\Windows\Temp\NerdioManagerLogs\ScriptedActions\zoom_sa\zoom_install_log.txt /qn /norestart" -Wait
Write-Host "INFO: Zoom client install finished."

# End Logging
Stop-Transcript
$VerbosePreference=$SaveVerbosePreference
