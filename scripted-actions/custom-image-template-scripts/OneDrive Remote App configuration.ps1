<#
  Author      : Markus Steigner & Cristian Schmitt Nieto
  Source      : https://learn.microsoft.com/azure/virtual-desktop/onedrive-remoteapp
#>

#description: Toggle background launch of Microsoft OneDrive for Azure Virtual Desktop RemoteApp sessions
#execution mode: Individual
#tags: CSN, Microsoft, Golden Image, Remote Apps, OneDrive

<#variables:
{
  "OneDriveBackgroundLaunch": {
    "Description": "Enable or disable launching OneDrive silently in the background for RemoteApp sessions.",
    "DisplayName": "OneDrive background launch",
    "IsRequired": true,
    "OptionsSet": [
      { "Label": "Enable",  "Value": "Enable" },
      { "Label": "Disable", "Value": "Disable" }
    ]
  }
}
#>


param (
  [Parameter(Mandatory)]
  [ValidateSet("Enable","Disable")]
  [string]$OneDriveBackgroundLaunch
)

# Registry paths
$tsKey  = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
$runKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"

# Ensure the TS policy key exists
if (-not (Test-Path $tsKey)) {
  New-Item -Path $tsKey -Force | Out-Null
}

switch ($OneDriveBackgroundLaunch) {
  "Enable" {
    Write-Host "Enabling OneDrive background launch for RemoteApp sessions…"

    # 1) Enable enhanced shell experience
    if (Get-ItemProperty -Path $tsKey -Name UseShellAppRuntimeRemoteApp -ErrorAction SilentlyContinue) {
      Set-ItemProperty -Path $tsKey -Name UseShellAppRuntimeRemoteApp -PropertyType DWord -Value 1 -Force
    }
    else {
      New-ItemProperty -Path $tsKey -Name UseShellAppRuntimeRemoteApp -PropertyType DWord -Value 1 -Force | Out-Null
    }

    # 2) Add OneDrive to Run, launching in background
    $oneDriveExe = Join-Path $env:ProgramFiles "Microsoft OneDrive\OneDrive.exe"
    $runValue    = "`"$oneDriveExe`" /background"
    if (Get-ItemProperty -Path $runKey -Name OneDrive -ErrorAction SilentlyContinue) {
      Set-ItemProperty -Path $runKey -Name OneDrive -PropertyType String -Value $runValue -Force
    }
    else {
      New-ItemProperty -Path $runKey -Name OneDrive -PropertyType String -Value $runValue -Force | Out-Null
    }
  }

  "Disable" {
    Write-Host "Disabling OneDrive background launch for RemoteApp sessions…"

    # Remove the TS shell-experience setting if present
    if (Get-ItemProperty -Path $tsKey -Name UseShellAppRuntimeRemoteApp -ErrorAction SilentlyContinue) {
      Remove-ItemProperty -Path $tsKey -Name UseShellAppRuntimeRemoteApp -ErrorAction SilentlyContinue
    }

    # Remove the Run entry for OneDrive if present
    if (Get-ItemProperty -Path $runKey -Name OneDrive -ErrorAction SilentlyContinue) {
      Remove-ItemProperty -Path $runKey -Name OneDrive -ErrorAction SilentlyContinue
    }
  }
}

Write-Host "Completed OneDrive background-launch configuration: $OneDriveBackgroundLaunch"