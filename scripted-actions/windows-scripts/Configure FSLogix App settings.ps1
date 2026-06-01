#description: Configures FSLogix App Service settings
#tags: Nerdio, FSLogix

<# Notes
- This script sets FSLogix App Service settings. To customize the settings, clone this script and modify the variables.
#>

# Variables for FSLogix App Service settings
$CleanupInvalidSessions = 1 # Cleans up invalid sessions to allow successful sign-in for user's next session.
$RoamRecycleBin = 1        # Redirects user's Recycle Bin into the VHD(x) container to allow restoring items from any machine.
$VHDCompactDisk = 1        # Compacts the VHD disk during sign out to decrease the Size On Disk depending on a predefined threshold.

# Set error action preference
$ErrorActionPreference = 'Stop'

# FSLogix App settings
Set-ItemProperty -Path HKLM:\Software\FSLogix\Apps -Name "CleanupInvalidSessions" -Type Dword -Value $CleanupInvalidSessions
# In cases where a user's session terminates abruptly, the VHD(x) mounted for the user's profile isn't properly detached and the user's next sign in may not successfully attach their VHD(x) container. Enable this setting and FSLogix attempts to clean up these invalid sessions and allow a successful sign-in. This setting affects both Profile and ODFC containers

Set-ItemProperty -Path HKLM:\Software\FSLogix\Apps -Name "RoamRecycleBin" -Type Dword -Value $RoamRecycleBin
# When enabled, this setting creates a redirection for the user's specific Recycle Bin into the VHD(x) container. This allows the user to restore items regardless of the machine from where they were deleted.

Set-ItemProperty -Path HKLM:\Software\FSLogix\Apps -Name "VHDCompactDisk" -Type Dword -Value $VHDCompactDisk
# When enabled, this setting attempts to compact the VHD disk during the sign out operation and is designed to automatically decrease the Size On Disk of the user's container depending on a predefined threshold
