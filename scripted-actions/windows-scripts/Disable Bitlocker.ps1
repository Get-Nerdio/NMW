#description: Checks if BitLocker is enabled and disables it prior to sysprep
#execution mode: Combined
#tags: Nerdio
<#
Notes:
This script checks if BitLocker is enabled on the OS drive and disables it if necessary.
This is a prerequisite for running Sysprep on the VM.
#>

# Define the log folder path and create it if it doesn't exist
$logFolder = Join-Path $env:TEMP "NMEScriptLogs"
if (-not (Test-Path $logFolder)) {
    New-Item -ItemType Directory -Path $logFolder | Out-Null
}

# Define the log file path with a timestamp
$logFile = Join-Path $logFolder "ScriptLog_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Function to write messages to the log file
function Write-Log {
    param (
        [string]$Message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $Message"
    Add-Content -Path $logFile -Value $logMessage
}

# Log the start of BitLocker status check
Write-Log "Checking BitLocker status on VM: $AzureVMName"

# Get the BitLocker protection status
$bitLockerStatus = Get-BitLockerVolume | Select-Object -ExpandProperty ProtectionStatus

# Check if BitLocker is enabled and disable it if necessary
if ($bitLockerStatus -eq 1) {
    Write-Log "BitLocker is enabled. Disabling BitLocker."
    Disable-BitLocker -MountPoint "C:"
    Write-Log "BitLocker has been disabled."
} else {
    Write-Log "BitLocker is not enabled. No action required."
}

# Log the completion of script execution
Write-Log "Script execution completed."

<#
RISK ASSESSMENT:
This script performs the following high-risk actions:
1. Disables BitLocker encryption on the OS drive

Overall risk level: Medium

Please review carefully and ensure you understand the implications before running this script.
It is recommended to test this script in a non-production environment first.
#>