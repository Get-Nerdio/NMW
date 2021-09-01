#description: Downloads and installs Zoom VDI client for AVD. Reference https://support.zoom.us/hc/en-us/articles/360052984292 (under "Windows Virtual Desktop") for more information
#execution mode: IndividualWithRestart
#tags: Nerdio, Apps install
<# 
Notes:
This script installs the Zoom VDI client for use on AVD Session hosts. 

IMPORTANT: In order to use Zoom's redirection, you must install the 
plugin for the Zoom client which used on the remote desktop client's machine.
The plugin can be found here: https://support.zoom.us/hc/en-us/articles/360052984292
under "Windows Virtual Desktop"
#>

# Start powershell logging
$SaveVerbosePreference = $VerbosePreference
$VerbosePreference = 'continue'
$VMTime = Get-Date
$LogTime = $VMTime.ToUniversalTime()
mkdir "C:\Windows\temp\NMWLogs\ScriptedActions\zoom_sa" -Force
Start-Transcript -Path "C:\Windows\temp\NMWLogs\ScriptedActions\zoom_sa\ps_log.txt" -Append
Write-Host "################# New Script Run #################"
Write-host "Current time (UTC-0): $LogTime"

# Make directory to hold install files
mkdir "C:\Windows\Temp\zoom_sa\install" -Force

# Parse through the Zoom VDI Help page to get the most up-to-date download link, then download installer files
Write-Host "INFO: Retrieving Zoom installer files. . ."
$ZoomDlSite = Invoke-WebRequest "https://support.zoom.us/hc/en-us/articles/360052984292" -UseBasicParsing
ForEach ($Href in $ZoomDLSite.Links.Href)
{
    if ($Href -match "ZoomInstallerVDI" ){
        $DLink = $href
        break
    }
}
Invoke-WebRequest -Uri $DLink -OutFile "C:\Windows\Temp\zoom_sa\install\ZoomInstallerVDI.msi" -UseBasicParsing

# Install Zoom. Edit the argument list as desired for customized installs: https://support.zoom.us/hc/en-us/articles/201362163
Write-Host "INFO: Installing Zoom. . ."
Start-Process C:\Windows\System32\msiexec.exe `
-ArgumentList "/i C:\Windows\Temp\zoom_sa\install\ZoomInstallerVDI.msi /l*v C:\Windows\Temp\NMWLogs\ScriptedActions\zoom_sa\zoom_install_log.txt /qn /norestart" -Wait
Write-Host "INFO: Zoom install finished."

# End Logging
Stop-Transcript
$VerbosePreference=$SaveVerbosePreference
