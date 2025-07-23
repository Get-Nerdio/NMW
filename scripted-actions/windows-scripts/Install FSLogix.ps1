#description: Downloads and installs the Microsoft FSLogix Agent on target session hosts
#Written by Johan Vanneuville
#No warranties given for this script
#execution mode: IndividualWithRestart
#tags: Nerdio, Apps install, FSLogix
<# 
    Notes:
    This script installs FSLogix on AVD Session hosts.
#>
$FslogixUrl = "https://aka.ms/fslogix/download"

# Start PowerShell logging
$VerbosePreference = "Continue"
$ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue # Suppress verbose output during script execution for faster performance
$VMTime = Get-Date
$LogTime = $VMTime.ToUniversalTime()
New-Item -Path "$Env:SystemRoot\Temp\NerdioManagerLogs\ScriptedActions\fslogix" -ItemType "Directory" -Force
Start-Transcript -Path "$Env:SystemRoot\Temp\NerdioManagerLogs\ScriptedActions\fslogix\ps_log.txt" -Append
Write-Host "################# New Script Run #################"
Write-Host "Current time (UTC-0): $LogTime"

# Make directory to hold install files
$SavePath = "$Env:SystemRoot\Temp\fslogix\install"
if (Test-Path -Path $SavePath) {
    Get-ChildItem -Path $SavePath | Remove-Item -Recurse -Force
}
New-Item -Path $SavePath -ItemType Directory -Force | Out-Null

# Download the FSLogix installer
try {
    if ($PSEdition -eq "Desktop") {
        Add-Type -AssemblyName "System.Net.Http"
        Add-Type -AssemblyName "System.Web"
    }
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    $HttpClient = New-Object -TypeName "System.Net.Http.HttpClient"
    $FslogixResolvedUrl = $HttpClient.SendAsync((New-Object -TypeName "System.Net.Http.HttpRequestMessage" -ArgumentList "HEAD", $FslogixUrl)).Result.RequestMessage.RequestUri.AbsoluteUri
    Write-Host "Resolved FSLogix download URL: $FslogixResolvedUrl"
    $HttpClient.Dispose()

    $params = @{
        Uri             = $FslogixResolvedUrl
        OutFile         = "$SavePath\FSLogixAppsSetup.zip"
        UseBasicParsing = $true
        ErrorAction     = "Stop"
    }
    Invoke-WebRequest @params
    Write-Host "Downloaded FSLogix installer to: $($OutFile.FullName)"
}
catch {
    Write-Host "ERROR: Failed to download FSLogix installer. Please check the URL or your network connection."
    Stop-Transcript
    exit 1
}

# Expand the installer
$params = @{
    LiteralPath     = "$SavePath\FSLogixAppsSetup.zip"
    DestinationPath = $SavePath
    Force           = $true
    ErrorAction     = "Stop"
}
Expand-Archive @params
Write-Host "Extracted FSLogix installer to: $SavePath"

# Find the installer from the extracted files and install
$Installers = Get-ChildItem -Path $SavePath -Recurse -Include "FSLogixAppsSetup.exe" | Where-Object { $_.Directory -match "x64" }
foreach ($Installer in $Installers) {
    Write-Host "Installing Microsoft FSLogix Apps agent"
    $params = @{
        FilePath     = $Installer.FullName
        ArgumentList = "/install /quiet /norestart /log `"$Env:SystemRoot\Temp\NerdioManagerLogs\ScriptedActions\fslogix\fslogix_install.log`""
        Wait         = $true
        PassThru     = $true
        ErrorAction  = "Stop"
    }
    $Result = Start-Process @params
    Write-Host "FSLogix installation process result: $($Result.ExitCode)"
}

# Clean up
Remove-Item -Path $SavePath -Recurse -Force -ErrorAction "Ignore"

# Remove an unnecessary shortcut
Start-Sleep -Seconds 5
$Shortcut = "$Env:ProgramData\Microsoft\Windows\Start Menu\FSLogix\FSLogix Apps Online Help.lnk"
Write-Host "Removing shortcut: $Shortcut"
Remove-Item -Path $Shortcut -Force -ErrorAction "Ignore"

# End Logging
Write-Host "INFO: FSLogix install finished."
Stop-Transcript
