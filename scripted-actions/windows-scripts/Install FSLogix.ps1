#description: Downloads and installs FSLogix on the session hosts
#Written by Johan Vanneuville
#No warranties given for this script
#execution mode: IndividualWithRestart
#tags: Nerdio, Apps install, FSLogix
<# 
Notes:
This script installs FSLogix on AVD Session hosts.

#>

$FslogixUrl = "https://aka.ms/fslogix_download"

# Start powershell logging
$SaveVerbosePreference = $VerbosePreference
$VerbosePreference = 'continue'
$VMTime = Get-Date
$LogTime = $VMTime.ToUniversalTime()
mkdir "C:\Windows\temp\NerdioManagerLogs\ScriptedActions\fslogix" -Force
Start-Transcript -Path "C:\Windows\temp\NerdioManagerLogs\ScriptedActions\fslogix\ps_log.txt" -Append
Write-Host "################# New Script Run #################"
Write-host "Current time (UTC-0): $LogTime"

# Make directory to hold install files

mkdir "C:\Windows\Temp\fslogix\install" -Force

Get-ChildItem C:\Windows\Temp\fslogix\install\ | Remove-Item -Recurse -Force

Invoke-WebRequest -Uri $FslogixUrl -OutFile "C:\Windows\Temp\fslogix\install\FSLogixAppsSetup.zip" -UseBasicParsing

Expand-Archive `
    -LiteralPath "C:\Windows\Temp\fslogix\install\FSLogixAppsSetup.zip" `
    -DestinationPath "C:\Windows\Temp\fslogix\install" `
    -Force `
    -Verbose
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
cd "C:\Windows\Temp\fslogix\install\"

$Dir = Get-ChildItem C:\Windows\Temp\fslogix\install\ | Where-Object PSIsContainer -eq $true
if ($Dir.Count -gt 1) {
    $Dir = Get-ChildItem C:\Windows\Temp\fslogix\ | Where-Object PSIsContainer -eq $true
}

# Install FSLogix. 
Write-Host "INFO: Installing FSLogix. . ."
Start-Process "$($Dir.FullName)\x64\Release\FSLogixAppsSetup.exe" `
    -ArgumentList "/install /quiet" `
    -Wait `
    -Passthru `
  


Write-Host "INFO: FSLogix install finished."

# End Logging
Stop-Transcript
$VerbosePreference=$SaveVerbosePreference
