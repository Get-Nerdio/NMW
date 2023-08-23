#description: Enables watermarking feature for remote desktop sessions
#tags: Nerdio

<# Notes:
    This script will enable the watermarking feature for remote desktop sessions.
    See https://learn.microsoft.com/en-us/azure/virtual-desktop/watermarking for more information.

    You may clone this script and adjust the registry values below to your needs.

#>

$regValues = @{
    "fEnableWatermarking"        = 1
    "fEnableTimeZoneRedirection" = 1
    "KeepAliveEnable"            = 1
    "KeepAliveInterval"          = 1
    "WatermarkingHeightFactor"   = 0xb4
    "WatermarkingOpacity"        = 0x7d0
    "WatermarkingQrScale"        = 4
    "WatermarkingWidthFactor"    = 0x140
}


# Download the AVDGPTemplate.cab file
$tempCabPath = "$env:TEMP\AVDGPTemplate.cab"
Invoke-WebRequest -Uri "https://aka.ms/avdgpo" -OutFile $tempCabPath

# Extract the .cab file
$tempExtractPath = "$env:TEMP\AVDGPTemplateExtract"
New-Item -Path $tempExtractPath -ItemType Directory -Force
expand.exe -F:* $tempCabPath "$tempExtractPath\AVDGPTemplate.zip"

# Extract the AVDGPTemplate.zip file
$zipPath = Join-Path -Path $tempExtractPath -ChildPath "AVDGPTemplate.zip"
$zipExtractPath = "$env:TEMP\AVDGPTemplateZipExtract"
New-Item -Path $zipExtractPath -ItemType Directory -Force
Expand-Archive -Path $zipPath -DestinationPath $zipExtractPath

# Copy all files from the zip extraction to %windir%\PolicyDefinitions
Copy-Item -Path "$zipExtractPath\*" -Destination "$env:windir\PolicyDefinitions" -Recurse -Force

# Edit the registry to create or enable the DWORD values
$regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services\"


foreach ($key in $regValues.Keys) {
    Set-ItemProperty -Path $regPath -Name $key -Value $regValues[$key] -Type DWord -Force
}

# clean up temp files
Remove-Item -Path $tempCabPath -Force
Remove-Item -Path $tempExtractPath -Force -Recurse
Remove-Item -Path $zipPath -Force
Remove-Item -Path $zipExtractPath -Force -Recurse

### End Script ###
