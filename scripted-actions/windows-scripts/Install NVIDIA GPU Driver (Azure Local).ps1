#description: Download and configure guest driver and license for NVidia GPUs
#execution mode: Combined
#tags: Nerdio, HCI
#Requires -RunAsAdministrator

<#Notes:
This script downloads and configures guest driver and license for NVidia GPUs

You must provide some variables to this script to determine where to download 
the driver and the client license token from. You can provide these variables as parameters 
when running the script, or as Secure Variables created in Nerdio Manager under Settings->Nerdio Integrations. 
If parameters passed at runtime are specified, they will override Secure Variables

If using Secure Variables, the variables to create in Nerdio Manager are:
  HciNvidiaGuestDriverUrl - url to download NVidia guest driver 
  HciNvidiaLicenseUrl - url to download NVidia client license
#>

<#variables:
{
  "driverUrl": {
    "Description": "Enter Nvidia guest driver URL",
    "DisplayName": "Nvidia guest driver URL"
  },
  "licenseTokenUrl": {
    "Description": "Enter Nvidia license token URL",
    "DisplayName": "Nvidia license token URL"
  }
}
#>

param (
  [ComponentModel.DisplayName('Nvidia guest driver url')]
  [string] $driverUrl,

  [ComponentModel.DisplayName('Nvidia license token url')]
  [string] $licenseTokenUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ([bool]$SecureVars.PSObject.Properties['HciNvidiaGuestDriverUrl']) {
  $azureDriverUrl = $SecureVars.HciNvidiaGuestDriverUrl
}
if ([bool]$SecureVars.PSObject.Properties['HciNvidiaLicenseUrl']) {
  $azureLicenseTokenUrl = $SecureVars.HciNvidiaLicenseUrl
}

if ($driverUrl) {
  $azureDriverUrl = $driverUrl
}

if ($licenseTokenUrl) {
  $azureLicenseTokenUrl = $licenseTokenUrl
}


function Test-RunningAsAdministrator {
  $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

if (-not (Test-RunningAsAdministrator)) {
  throw 'Administrator privileges are required. Please run PowerShell as Administrator.'
}

# Ensure TLS 1.2 is enabled for downloads
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.ServicePointManager]::SecurityProtocol
} catch { }

function New-TempDirectory {
  # Create a unique temporary working directory
  $dir = Join-Path -Path $env:TEMP -ChildPath ("nv-{0}" -f ([guid]::NewGuid().ToString('N')))
  New-Item -Path $dir -ItemType Directory -Force | Out-Null
  return $dir
}

function Get-FilenameFromUrl {
  param([string]$Url)
  # Extract the file name from URL path
  $uri = [Uri]$Url
  $leaf = [IO.Path]::GetFileName($uri.AbsolutePath)
  if ([string]::IsNullOrWhiteSpace($leaf)) { return 'download.bin' }
  # Strip query/fragment if present
  return $leaf -replace '[\?\#].*$', ''
}

function Download-File {
  param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$DestinationPath
  )
  # Download and verify the file exists
  Invoke-WebRequest -Uri $Url -OutFile $DestinationPath
  if (-not (Test-Path -LiteralPath $DestinationPath)) {
    throw "Failed to download file: $Url"
  }
}

function Install-NvidiaDriver {
  param([Parameter(Mandatory)][string]$DriverPath)

  # MSI branch
  if ($DriverPath -match '\.msi$') {
    $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', $DriverPath, '/qn', '/norestart') -Wait -PassThru
    return $proc.ExitCode
  }

  # Try common silent switches: -s -noreboot
  $proc = Start-Process -FilePath $DriverPath -ArgumentList @('-s','-noreboot') -Wait -PassThru
  if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
    return $proc.ExitCode
  }

  # Fallback to /s /noreboot (some installers use slash switches)
  $proc2 = Start-Process -FilePath $DriverPath -ArgumentList @('/s','/noreboot') -Wait -PassThru
  return $proc2.ExitCode
}

$workDir = New-TempDirectory
try {
  # Download driver
  $driverFileName = Get-FilenameFromUrl -Url $azureDriverUrl
  $driverPath = Join-Path -Path $workDir -ChildPath $driverFileName
  Download-File -Url $azureDriverUrl -DestinationPath $driverPath

  # Install driver silently
  $installCode = Install-NvidiaDriver -DriverPath $driverPath
  if ($installCode -ne 0 -and $installCode -ne 3010) {
    throw "Driver installation finished with exit code $installCode"
  }

  # Download license token
  $tokenFileName = Get-FilenameFromUrl -Url $azureLicenseTokenUrl
  $tokenTmpPath = Join-Path -Path $workDir -ChildPath $tokenFileName
  Download-File -Url $azureLicenseTokenUrl -DestinationPath $tokenTmpPath

  # Destination directory for the token
  $tokenDestDir = Join-Path $env:SystemDrive 'Program Files\NVIDIA Corporation\vGPU Licensing\ClientConfigToken'
  New-Item -Path $tokenDestDir -ItemType Directory -Force | Out-Null

  # Copy token to destination
  $tokenDestPath = Join-Path -Path $tokenDestDir -ChildPath $tokenFileName
  Copy-Item -LiteralPath $tokenTmpPath -Destination $tokenDestPath -Force

  # Restart NVDisplay.Container* services
  $services = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'NVDisplay.Container*' }
  if ($services) {
    foreach ($svc in $services) {
      try {
        Write-Host "Restarting service: $($svc.Name)"
        Restart-Service -Name $svc.Name -Force -ErrorAction Stop
      } catch {
        try {
          Write-Host "Restart failed, trying stop/start for: $($svc.Name)"
          Stop-Service -Name $svc.Name -Force -ErrorAction Stop
          Start-Service -Name $svc.Name -ErrorAction Stop
        } catch {
          Write-Warning "Failed to restart service $($svc.Name): $($_.Exception.Message)"
        }
      }
    }
  } else {
    Write-Host "No services found matching 'NVDisplay.Container*'."
  }

  Write-Host "Driver installed. Exit code: $installCode"
  if ($installCode -eq 3010) {
    Write-Host "A restart is required to complete the driver installation."
  }
  Write-Host "Token copied to: $tokenDestPath"
}
finally {
  # Clean up temporary files
  Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}
