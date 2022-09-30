#description: Installs/Updates MS Teams and WebRTC Service with newest versions. Enables Teams AVD Optimization mode. Recommend to run regularly on Desktop Images.
#execution mode: IndividualWithRestart
#tags: Nerdio, Apps install
<# 
Notes:
This script performs the following:
1. Sets registry value for MS Teams to AVD Mode
2. Uninstall MSTeams and WebRTC program
3. Downloads and Installs latest version of MS Teams machine-wide (Not per-user)
4. Downloads and Installs latest version of WebRTC component
5. Sends logs to C:Windows\temp\NMWLogs\ScriptedActions\msteams
#>

# Start powershell logging
$SaveVerbosePreference = $VerbosePreference
$VerbosePreference = 'continue'
$VMTime = Get-Date
$LogTime = $VMTime.ToUniversalTime()
mkdir "C:\Windows\temp\NMWLogs\ScriptedActions\msteams" -Force
Start-Transcript -Path "C:\Windows\temp\NMWLogs\ScriptedActions\msteams\ps_log.txt" -Append
Write-Host "################# New Script Run #################"
Write-host "Current time (UTC-0): $LogTime"

# set registry values for Teams to use VDI optimization 
Write-Host "INFO: Adjusting registry to set Teams to AVD Environment mode" -ForegroundColor Gray
reg add HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Teams /v "IsWVDEnvironment" /t REG_DWORD /d 1 /f

# uninstall any previous versions of MS Teams or Web RTC
# Per-user teams uninstall logic 
$TeamsPath = [System.IO.Path]::Combine($env:LOCALAPPDATA, 'Microsoft', 'Teams')
$TeamsUpdateExePath = [System.IO.Path]::Combine($env:LOCALAPPDATA, 'Microsoft', 'Teams', 'Update.exe')
try {
    if ([System.IO.File]::Exists($TeamsUpdateExePath)) {
        Write-Host "INFO: Uninstalling Teams process (per-user installation)"

        # Uninstall app
        $proc = Start-Process $TeamsUpdateExePath "-uninstall -s" -PassThru
        $proc.WaitForExit()
    }
    else {
        write-host "INFO: No per-user teams install found."
    }
    Write-Host "INFO: Deleting any possible Teams directories (per user installation)."
    Remove-Item -path $TeamsPath -recurse -ErrorAction SilentlyContinue
}
catch  {
    Write-Output "Uninstall failed with exception $_.exception.message"
}

# Per-Machine teams uninstall logic
$GetTeams = get-wmiobject Win32_Product | Where-Object IdentifyingNumber -match "{731F6BAA-A986-45A4-8936-7C3AAAAA760B}"
if ($null -ne $GetTeams){
    Start-Process C:\Windows\System32\msiexec.exe -ArgumentList '/x "{731F6BAA-A986-45A4-8936-7C3AAAAA760B}" /qn /norestart' -Wait
    Write-Host "INFO: Teams per-machine Install Found, uninstalling teams"
}

# WebRTC uninstall logic
$GetWebRTC = get-wmiobject Win32_Product | Where-Object IdentifyingNumber -match "{FB41EDB3-4138-4240-AC09-B5A184E8F8E4}"
if ($null -ne $GetWebRTC){
    Start-Process C:\Windows\System32\msiexec.exe -ArgumentList '/x "{FB41EDB3-4138-4240-AC09-B5A184E8F8E4}" /qn /norestart' -Wait
    Write-Host "INFO: WebRTC Install Found, uninstalling Current version of WebRTC"
}

# make directories to hold new install 
mkdir "C:\Windows\Temp\msteams_sa\install" -Force

# grab MSI installer for MSTeams
$DLink = "https://teams.microsoft.com/downloads/desktopurl?env=production&plat=windows&arch=x64&managedInstaller=true&download=true"
Invoke-WebRequest -Uri $DLink -OutFile "C:\Windows\Temp\msteams_sa\install\Teams_windows_x64.msi" -UseBasicParsing

# use installer to install Machine-Wide
Write-Host "INFO: Installing MS Teams"
Start-Process C:\Windows\System32\msiexec.exe `
-ArgumentList  '/i C:\Windows\Temp\msteams_sa\install\Teams_windows_x64.msi /l*v C:\Windows\temp\NMWLogs\ScriptedActions\msteams\teams_install_log.txt ALLUSER=1 ALLUSERS=1 /qn /norestart' -Wait

# use MS shortcut to WebRTC install
$dlink2 = "https://aka.ms/msrdcwebrtcsvc/msi"

Invoke-WebRequest -Uri $DLink2 -OutFile "C:\Windows\Temp\msteams_sa\install\MsRdcWebRTCSvc_x64.msi" -UseBasicParsing

# install Teams WebRTC Websocket Service
Write-Host "INFO: Installing WebRTC component"
Start-Process C:\Windows\System32\msiexec.exe `
-ArgumentList '/i C:\Windows\Temp\msteams_sa\install\MsRdcWebRTCSvc_x64.msi /l*v C:\Windows\temp\NMWLogs\ScriptedActions\msteams\WebRTC_install_log.txt /qn /norestart' -Wait
Write-Host "INFO: Finished running installers. Check C:\Windows\Temp\msteams_sa for logs on the MSI installations."
Write-Host "INFO: All Commands Executed; script is now finished. Allow 5 minutes for teams to appear" -ForegroundColor Green

# End Logging
Stop-Transcript
$VerbosePreference=$SaveVerbosePreference
