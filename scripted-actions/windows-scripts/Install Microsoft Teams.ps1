#description: Installs/Updates MS Teams and WebRTC Service with newest versions. Enables Teams WVD Optimization mode. Recommend to run regularly on Desktop Images.
#execution mode: IndividualWithRestart
#tags: Nerdio, Apps install
<# 
    This script preforms the follwoing:
    1. Sets registry valye for teams to WVD Mode
    2. Uninstall MSTeams and WebRTC program
    3. Downloads and Installs latest version of MSTeams machine-wide (Not per-user)
    4. Downloads and Installs latest version of WebRTC component
    5. Sends logs to \System32\NMWLogs\ScriptedActions\msteams
#>

# Configure powershell logging
mkdir "C:\Windows\System32\NMWLogs\ScriptedActions\msteams" -Force
Start-Transcript -Path "C:\Windows\System32\NMWLogs\ScriptedActions\msteams\install\ps_log.log" -Append
Write-Host "######################################
New Script Run, current time (UTC-0):"
$Time = Get-Date
$Time.ToUniversalTime()

# set registry values for Teams to use VDI optimization 
Write-Host "Adjusting registry to set teams to WVD Environment mode" -ForegroundColor Gray
reg add HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Teams /v "IsWVDEnvironment" /t REG_DWORD /d 1 /f

#region Uninstall Previous Versions
# uninstall any previous versions of MS Teams or Web RTC

# Per-user teams uninstall logic 
$TeamsPath = [System.IO.Path]::Combine($env:LOCALAPPDATA, 'Microsoft', 'Teams')
$TeamsUpdateExePath = [System.IO.Path]::Combine($env:LOCALAPPDATA, 'Microsoft', 'Teams', 'Update.exe')

try {
    if ([System.IO.File]::Exists($TeamsUpdateExePath)) {
        Write-Host "Uninstalling Teams process (per-user installation)"

        # Uninstall app
        $proc = Start-Process $TeamsUpdateExePath "-uninstall -s" -PassThru
        $proc.WaitForExit()
    }
    else {
        write-host "No per-user teams install found."
    }
    Write-Host "Deleting any possible Teams directories (per user installation)."
    Remove-Item -path $TeamsPath -recurse -ErrorAction SilentlyContinue

}
catch  {
    Write-Output "Uninstall failed with exception $_.exception.message"
}

# Per-Machine teams uninstall logic
$GetTeams = get-wmiobject Win32_Product | Where-Object IdentifyingNumber -match "{731F6BAA-A986-45A4-8936-7C3AAAAA760B}"
if ($null -ne $GetTeams){
    Start-Process C:\Windows\System32\msiexec.exe -ArgumentList '/x "{731F6BAA-A986-45A4-8936-7C3AAAAA760B}" /qn /norestart' -Wait
    Write-Host "Teams per-machine Install Found, uninstalling teams"
}

# WebRTC uninstall logic
$GetWebRTC = get-wmiobject Win32_Product | Where-Object IdentifyingNumber -match "{FB41EDB3-4138-4240-AC09-B5A184E8F8E4}"
if ($null -ne $GetWebRTC){
    Start-Process C:\Windows\System32\msiexec.exe -ArgumentList '/x "{FB41EDB3-4138-4240-AC09-B5A184E8F8E4}" /qn /norestart' -Wait
    Write-Host "WebRTC Install Found, uninstalling Current version of WebRTC"
}

#endregion

#region Download and Install Teams + WebRTC

# make directories to hold new install 
mkdir "C:\Windows\Temp\msteams_sa\install" -Force

# grab MSI installer for MSTeams
$DLink = "https://teams.microsoft.com/downloads/desktopurl?env=production&plat=windows&arch=x64&managedInstaller=true&download=true"
Invoke-WebRequest -Uri $DLink -OutFile "C:\Windows\Temp\msteams_sa\install\Teams_windows_x64.msi" -UseBasicParsing

# use installer to install Machine-Wide
Start-Process C:\Windows\System32\msiexec.exe -ArgumentList  '/i C:\Windows\Temp\msteams_sa\install\Teams_windows_x64.msi /l*v C:\Windows\System32\NMWLogs\ScriptedActions\msteams\teams_install_log.txt ALLUSER=1 ALLUSERS=1 /qn /norestart' -wait


# get MS Docs page that has WebRTC Download link
$MSDlSite2 = Invoke-WebRequest "https://docs.microsoft.com/en-us/azure/virtual-desktop/teams-on-wvd" -UseBasicParsing

# parse through the MS Docs page to get the most up-to-date download link
ForEach ($Href in $MSDlSite2.Links.Href)
{
    if ($Href -match "https://query.prod.cms.rt.microsoft.com/cms/api/am/binary" ){
        $DLink2 = $href
    }
}
Invoke-WebRequest -Uri $DLink2 -OutFile "C:\Windows\Temp\msteams_sa\install\MsRdcWebRTCSvc_x64.msi" -UseBasicParsing

# install Teams Websocket Service
Start-Process C:\Windows\System32\msiexec.exe -ArgumentList '/i C:\Windows\Temp\msteams_sa\install\MsRdcWebRTCSvc_x64.msi /l*v C:\Windows\System32\NMWLogs\ScriptedActions\msteams\WebRTC_install_log.txt /qn /norestart' -Wait

write-host "Finished running installers. Check C:\Windows\Temp\msteams_sa for logs on the MSI installations."

#endregion

Write-Host "All Commands Executed; script is now finished. Allow 5 minutes for teams to appear" -ForegroundColor Green

Stop-Transcript