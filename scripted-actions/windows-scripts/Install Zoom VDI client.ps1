#description: Downloads and installs Zoom VDI client for WVD. Reference https://support.zoom.us/hc/en-us/articles/360052984292 (under "Windows Virtual Desktop") for more information
#execution mode: IndividualWithRestart
#tags: Nerdio, Apps install
<# 
Notes:
This script installs the Zoom VDI client for use on WVD Session hosts. 

IMPORTANT: In order to use Zoom's redirection, you must install the 
plugin for the Zoom client which used on the remote desktop client's machine.
The plugin can be found here: https://support.zoom.us/hc/en-us/articles/360052984292
under "Windows Virtual Desktop"
#>

# Configure powershell logging
mkdir "C:\Windows\Temp\NMWLogs\ScriptedActions\zoom_sa" -Force
Start-Transcript -Path "C:\Windows\Temp\NMWLogs\ScriptedActions\zoom_sa\ps_log.log" -Append
Write-Host "######################################
New Script Run, current time (UTC-0):"
$Time = Get-Date
$Time.ToUniversalTime()

# Make directory to hold install files
mkdir C:\Windows\Temp\zoom_sa\install

# parse through the Zoom VDI Help page to get the most up-to-date download link
$ZoomDlSite = Invoke-WebRequest "https://support.zoom.us/hc/en-us/articles/360052984292" -UseBasicParsing

ForEach ($Href in $ZoomDLSite.Links.Href)
{
    if ($Href -match "ZoomInstallerVDI" ){
        $DLink = $href
        break
    }
}
# Download Zoom installer from Zoom Website
Invoke-WebRequest -Uri $DLink -OutFile "C:\Windows\Temp\zoom_sa\install\ZoomInstallerVDI.msi" -UseBasicParsing

# install Zoom. Edit this as desired for customized installs: https://support.zoom.us/hc/en-us/articles/201362163
Start-Process C:\Windows\System32\msiexec.exe -ArgumentList "/i C:\Windows\Temp\zoom_sa\install\ZoomInstallerVDI.msi /l*v C:\Windows\Temp\NMWLogs\zoom_sa\zoom_install_log.txt /qn /norestart"
