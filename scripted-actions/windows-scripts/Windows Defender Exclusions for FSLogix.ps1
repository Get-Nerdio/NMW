#description: Adds specified paths to Defender's exclusion list
#tags: Nerdio, Defender

<#
Notes:
This script will add specified paths to the Defender's exclusion list.
Please replace the '\\server\share' value with actual value before running the script.
#>

# Define the fslogix path. Replace these with actual value.
$FSLogixPath = '\\server\share'

# Define the exclusion paths
$ExclusionPaths = @(
    "$env:TEMP\*\*.VHD",
    "$env:TEMP\*\*.VHDX",
    "$env:Windir\TEMP\*\*.VHD",
    "$env:Windir\TEMP\*\*.VHDX",
    "\\$FSLogixPath\*\*.VHD",
    "\\$FSLogixPath\*\*.VHD.lock",
    "\\$FSLogixPath\*\*.VHD.meta",
    "\\$FSLogixPath\*\*.VHD.metadata",
    "\\$FSLogixPath\*\*.VHDX",
    "\\$FSLogixPath\*\*.VHDX.lock",
    "\\$FSLogixPath\*\*.VHDX.meta",
    "\\$FSLogixPath\*\*.VHDX.metadata",
    "$env:ProgramData\FSLogix\Cache\*", # Needed for Cloud Cache
    "$env:ProgramData\FSLogix\Proxy\*" # Needed for Cloud Cache
)

# Ensure Defender module is available on the system
if(!(Get-Module -ListAvailable -Name Defender)) {
    Write-Output "Defender module not found on the system"
    Exit
}

# Add the paths to Defender's exclusion list
foreach ($Path in $ExclusionPaths) {
    Add-MpPreference -ExclusionPath $Path
    Write-Output "Added $Path to Defender's exclusion list"
}

### End Script ###
