<#
  Author      : Cristian Schmitt Nieto
  Source      : https://learn.microsoft.com/en-us/troubleshoot/windows-client/group-policy/using-group-policy-objects-hide-specified-drives
#>

#description : Hide or unhide drives in File Explorer by managing the NoDrives policy.
#execution mode: IndividualWithRestart
#tags: CSN, Windows Script, Golden Image, Explorer, Drive Visibility

<#variables:
{
  "Action": {
    "optionsSet": [
      { "label": "Hide specified drives",     "value": "Hide"   },
      { "label": "Unhide all drives", "value": "Unhide" }
    ]
  },
  "DrivesToHide": {
    "description": "Comma‑separated list of drive letters to hide (e.g. C,D,E,F). Only used when Action is Hide.",
    "isRequired": false,
    "defaultValue": ""
  }
}
#>


param(
  [ComponentModel.DisplayName('Action')]
  [Parameter(Mandatory)]
  [ValidateSet('Hide','Unhide')]
  [string]$Action = 'Hide',

  [ComponentModel.DisplayName('Drives to hide (Only use if Hide Option is selected)')]
  [Parameter()]
  [string]$DrivesToHide = ''
)

$regPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'

# Ensure the Explorer policy key exists
if (-not (Test-Path $regPath)) {
  New-Item -Path $regPath -Force | Out-Null
}

if ($Action -eq 'Unhide') {
  if (Get-ItemProperty -Path $regPath -Name 'NoDrives' -ErrorAction SilentlyContinue) {
    Remove-ItemProperty -Path $regPath -Name 'NoDrives' -ErrorAction Stop
    Write-Host "Removed NoDrives entry; all drives will be visible."
  }
  else {
    Write-Host "NoDrives entry not found; nothing to remove."
  }
  return
}

# Action = Hide
if ([string]::IsNullOrWhiteSpace($DrivesToHide)) {
  throw "DrivesToHide must be specified when Action is 'Hide'."
}

# Drive bitmask map
$driveMap = @{
  A=1; B=2; C=4; D=8;  E=16; F=32;  G=64;   H=128;
  I=256; J=512; K=1024; L=2048; M=4096; N=8192; O=16384; P=32768;
  Q=65536; R=131072; S=262144; T=524288; U=1048576; V=2097152; W=4194304; X=8388608;
  Y=16777216; Z=33554432
}

# Parse & validate
$letters = $DrivesToHide.Split(',') | ForEach-Object { $_.Trim().ToUpper() }
$mask = 0
foreach ($letter in $letters) {
  if ($driveMap.ContainsKey($letter)) {
    $mask += $driveMap[$letter]
  }
  else {
    throw "Invalid drive letter specified: '$letter'"
  }
}

# Create or update the NoDrives DWORD
if (Get-ItemProperty -Path $regPath -Name 'NoDrives' -ErrorAction SilentlyContinue) {
  Set-ItemProperty -Path $regPath -Name 'NoDrives' -Value $mask -Type DWord -Force
  Write-Host "Updated NoDrives to $mask; hidden drives: $($letters -join ', ')."
}
else {
  New-ItemProperty -Path $regPath -Name 'NoDrives' -Value $mask -PropertyType DWord -Force | Out-Null
  Write-Host "Created NoDrives = $mask; hidden drives: $($letters -join ', ')."
}

Write-Host "Please restart Explorer or reboot for changes to take effect."
