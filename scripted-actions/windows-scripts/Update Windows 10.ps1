#description: Installs latest Windows 10 updates
#execution mode: IndividualWithRestart
#tags: Nerdio
<#
Notes:
This script will install all windows updates using PSWindowsUpdate 
See: https://www.powershellgallery.com/packages/PSWindowsUpdate for details
#>

# Ensure NuGet is installed on system
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force

# install latest version of PSWindwosUpdate
Install-Module PSWindowsUpdate -Force

# install all windows updates
Install-WindowsUpdate -AcceptAll -ForceInstall -IgnoreReboot
