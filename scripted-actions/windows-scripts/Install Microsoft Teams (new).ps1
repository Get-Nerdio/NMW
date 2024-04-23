#description: Installs/Updates New MS Teams client. Enables Teams WVD Optimization mode.
#execution mode: IndividualWithRestart
#tags: Nerdio, Apps install
<#
Notes:
This script performs the following:
1. Sets registry value for MS Teams to WVD Mode
2. Uninstall MSTeams and WebRTC program
3. Downloads and Installs latest version of MS Teams machine-wide (Not per-user)
4. Downloads and Installs latest version of WebRTC component
5. Sends logs to C:\Windows\temp\NerdioManagerLogs\ScriptedActions\msteams
#>
 
# Start powershell logging
$SaveVerbosePreference = $VerbosePreference
$VerbosePreference = 'continue'
$VMTime = Get-Date
$LogTime = $VMTime.ToUniversalTime()
mkdir "C:\Windows\temp\NerdioManagerLogs\ScriptedActions\msteams" -Force
Start-Transcript -Path "C:\Windows\temp\NerdioManagerLogs\ScriptedActions\msteams\ps_log.txt" -Append
Write-Host "################# New Script Run #################"
Write-host "Current time (UTC-0): $LogTime"
 
if (!(Test-Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}\') -and !(Test-Path 'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}\')) {
    # download WebView2 installer from https://go.microsoft.com/fwlink/p/?LinkId=2124703
    Write-Host "INFO: Installing WebView2"
    $WebView2Installer = "C:\Windows\temp\NerdioManagerLogs\ScriptedActions\msteams\MicrosoftEdgeWebView2Setup.exe"
    $WebView2InstallerUrl = "https://go.microsoft.com/fwlink/p/?LinkId=2124703"
    Invoke-WebRequest -Uri $WebView2InstallerUrl -OutFile $WebView2Installer -UseBasicParsing
    Start-Process $WebView2Installer -ArgumentList '/silent /install' -Wait
}
 
# set registry values for Teams to use VDI optimization
Write-Host "INFO: Adjusting registry to set Teams to WVD Environment mode" -ForegroundColor Gray
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
    Start-Process C:\Windows\System32\msiexec.exe -ArgumentList '/x "{731F6BAA-A986-45A4-8936-7C3AAAAA760B}" /qn /norestart' -Wait 2>&1
    Write-Host "INFO: Teams per-machine Install Found, uninstalling teams"
}
 
# WebRTC uninstall logic
$GetWebRTC = get-wmiobject Win32_Product | Where-Object Name -match "Remote Desktop WebRTC Redirector Service"
if ($null -ne $GetWebRTC){
    $WebRTCProductCode = $GetWebRTC | Select-Object -ExpandProperty IdentifyingNumber
    Start-Process C:\Windows\System32\msiexec.exe -ArgumentList "/x $WebRTCProductCode /qn /norestart" -Wait 2>&1
    Write-Host "INFO: WebRTC Install Found, uninstalling Current version of WebRTC"
}

# Teams Meeting add-in uninstall logic
$GetAddIn = get-wmiobject Win32_Product | Where-Object Name -match "Microsoft Teams Meeting Add-in for Microsoft Office"
if ($null -ne $GetAddIn){
    $AddInProductCode = $GetAddIn | Select-Object -ExpandProperty IdentifyingNumber
    Start-Process C:\Windows\System32\msiexec.exe -ArgumentList "/x $AddInProductCode /qn /norestart" -Wait 2>&1
    Write-Host "INFO: Teams Meeting Add-in Found, uninstalling Current version of Teams Meeting Add-in"
}
 
# make directories to hold new install
mkdir "C:\Windows\Temp\msteams_sa\install" -Force
 
# grab MSI installer for MSTeams
$DLink = "https://go.microsoft.com/fwlink/?linkid=2243204&clcid=0x409"
Invoke-WebRequest -Uri $DLink -OutFile "C:\Windows\Temp\msteams_sa\install\teamsbootstrapper.exe" -UseBasicParsing
 
# use installer to install Machine-Wide
Write-Host "INFO: Installing MS Teams"
Start-Process C:\Windows\Temp\msteams_sa\install\teamsbootstrapper.exe -ArgumentList '-p'
 
# use MS shortcut to WebRTC install
$dlink2 = "https://aka.ms/msrdcwebrtcsvc/msi"
 
# grab MSI installer for WebRTC
Invoke-WebRequest -Uri $DLink2 -OutFile "C:\Windows\Temp\msteams_sa\install\MsRdcWebRTCSvc_x64.msi" -UseBasicParsing
 
# install Teams WebRTC Websocket Service
Write-Host "INFO: Installing WebRTC component"
Start-Process C:\Windows\System32\msiexec.exe `
-ArgumentList '/i C:\Windows\Temp\msteams_sa\install\MsRdcWebRTCSvc_x64.msi /l*v C:\Windows\temp\NerdioManagerLogs\ScriptedActions\msteams\WebRTC_install_log.txt /qn /norestart' -Wait 2>&1
Write-Host "INFO: Finished running installers. Check C:\Windows\Temp\msteams_sa for logs on the MSI installations."
Write-Host "INFO: All Commands Executed; script is now finished. Allow 5 minutes for teams to appear" -ForegroundColor Green

# install Teams Meeting add-in
$TeamsVersion = (Get-AppxPackage -Name MSTeams).Version
$TMAPath = "{0}\WINDOWSAPPS\MSTEAMS_{1}_X64__8WEKYB3D8BBWE\MICROSOFTTEAMSMEETINGADDININSTALLER.MSI" -f $env:programfiles,$TeamsVersion
$TMAVersion = (Get-AppLockerFileInformation -Path $TMAPath | Select-Object -ExpandProperty Publisher).BinaryVersion
$TargetDir = "{0}\Microsoft\TeamsMeetingAddin\{1}\" -f ${env:ProgramFiles(x86)},$TMAVersion
$params = '/i "{0}" TARGETDIR="{1}" /qn ALLUSERS=1' -f $TMAPath, $TargetDir
Write-Host "INFO: Installing Teams Meeting add-in"
Start-Process msiexec.exe -ArgumentList $params
Write-Host "INFO: Finished running installers. Check C:\Windows\Temp\msteams_sa for logs on the MSI installations."
Write-Host "INFO: All Commands Executed; script is now finished. Allow 5 minutes for teams to appear" -ForegroundColor Green
 
# End Logging
Stop-Transcript
$VerbosePreference=$SaveVerbosePreference
