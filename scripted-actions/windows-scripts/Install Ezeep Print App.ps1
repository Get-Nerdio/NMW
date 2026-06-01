#description: Downloads and installs ezeepPrintApp.exe

<#
Notes:
This script will download the ezeepPrintApp.exe file from Ezeep server and install it.
#>

$EzeepSetupUrl = "https://ezeep.io/windows"
$DownloadPath = "C:\Temp\ezeepPrintApp.exe"

if (!(Test-Path -Path "C:\Temp")) {
    New-Item -ItemType Directory -Path "C:\Temp"
}


# Downloading ezeep print app package
Write-Host "Downloading Ezeep Print App..."
Invoke-WebRequest -Uri $EzeepSetupUrl -OutFile $DownloadPath

<#
Extracting files according to the instruction
https://support.ezeep.com/en/support/solutions/articles/43000665972-msi-deployment-of-the-ezeep-print-app
#>
Write-Host "Extracting Ezeep archive"
Start-Process -FilePath $DownloadPath -ArgumentList '/s /a"C:\temp\extract\SetupPrerequisites" /b"C:\temp\extract\FullMSI" /v"TARGETDIR=C:\temp\extract /qb"' -Wait


# Installing required packages, without them an error 1722 appears

Write-Host "Installing vcredist"
$VcredistPath = "C:\Temp\extract\SetupPrerequisites\{49CE81AF-01AB-4DE6-8995-598B5F682F66}\vcredist_x64.exe"
Start-Process -FilePath $VcredistPath -ArgumentList '/install /quiet /norestart' -Wait

Write-Host "Installing .Net 8 Desktop Runtime"
$DotNet8Path = "C:\Temp\extract\SetupPrerequisites\Microsoft .NET 8 Desktop Runtime - 8.0.0\windowsdesktop-runtime-8.0.0-win-x64.exe"
Start-Process -FilePath $DotNet8Path -ArgumentList '/install /quiet /norestart' -Wait

Write-Host "Installing .Net Framework 4.6"
$DotNet46Path = "C:\Temp\extract\SetupPrerequisites\Microsoft .NET Framework 4.6\NDP46-KB3045557-x86-x64-AllOS-ENU.exe"
Start-Process -FilePath $DotNet46Path -ArgumentList '/q /norestart' -Wait

Write-Host "Installing Edge WebView 2.0"
$EdgeWebViewPath = "C:\Temp\extract\SetupPrerequisites\Microsoft Edge WebView2 Runtime\MicrosoftEdgeWebview2Setup.exe"
Start-Process -FilePath $EdgeWebViewPath -ArgumentList '/silent /install' -Wait


# Installing Ezeep Print App

Write-Host "Installing Ezeep Print App"
Start-Process -FilePath msiexec.exe -ArgumentList '/i "C:\Temp\extract\FullMSI\ezeep Print App.msi" /quiet' -Wait

Write-Host "Done"

### End Script ###
