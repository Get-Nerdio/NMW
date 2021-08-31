#description: Unassigns a user from a personal desktop
#tags: Nerdio, Preview

<#
Notes:

This runbook only works on ARM (Spring 2020) host pools, not pre-ARM (Fall 2019)

This runbook relies on the Az.DesktopVirtualization powershell module. 
This module must be installed into the Nerdio manager scripted actions automation account. 
See here for information on installing modules:

https://docs.microsoft.com/en-us/azure/automation/shared-resources/modules

Start this runbook by going to the host pool, clicking "Manage Hosts" and selecting "Run script"
from the drop-down menu for the host.

#>

<# Variables:
#>

import-module Az.DesktopVirtualization 

if (get-module Az.DesktopVirtualization) {
   write-output "Az.DesktopVirtualization module present"
}
else {
   Throw "Az.DesktopVirtualization module not present. Install the module in the nerdio runbook Automation Account."
   exit
}

if ($AzureResourceGroupName -eq '')
{
  Write-Error "Unable to resolve ResourceGroupName. Host Pool may not be ARM (Spring 2020) release."
  exit
}


$VMResourceGroupName = $AzureResourceGroupName
$HostPoolResourceGroupName = $HostPoolId.Split('/', [System.StringSplitOptions]::RemoveEmptyEntries)[3]

write-output "getting vm"
$VM = Get-AzVM -ResourceGroupName $VMResourceGroupName -Name $AzureVMName

$VMStatus = Get-AzVM -ResourceGroupName $VMResourceGroupName -Name $AzureVMName -Status
if (!($VMStatus.Statuses.code -match 'running')) {
    Write-Output "Starting VM $AzureVMName"
    $VM | Start-AzVM 
}


# Generate New Registration Token
Write-Output "Generate New Registration Token"
$RegistrationKey = New-AzWvdRegistrationInfo -ResourceGroupName $HostPoolResourceGroupName -HostPoolName $HostPoolName -ExpirationTime $((get-date).ToUniversalTime().AddDays(1).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'))
 
# Making AzureVMName Fully Qualified
$tag = $vm.tags.Keys -match 'VM_FQDN'
$AzureVMNameFQDN = $vm.Tags[$tag][0]

# Get host pool and app group
$hp = Get-AzWvdHostPool -Name $HostPoolName -ResourceGroupName $HostPoolResourceGroupName
$AppGroupName = ($hp.ApplicationGroupReference -split '/')[-1]

# Removing user from App Group

$SessionHost = Get-AzWvdSessionHost -HostPoolName $HostPoolName -Name $AzureVMNameFQDN -ResourceGroupName $HostPoolResourceGroupName
$DesktopUser = $SessionHost.AssignedUser

if ($DesktopUser -eq $null) {
    Write-Error "No user is assigned to session host"
    exit
}

Write-Output "Removing user $desktopUser from the app group $AppGroupName"

Remove-AzRoleAssignment -SignInName $DesktopUser -RoleDefinitionName 'Desktop Virtualization User' -ResourceName "$AppGroupName" -ResourceGroupName $HostPoolResourceGroupName -ResourceType 'Microsoft.DesktopVirtualization/applicationGroups' 

# Removing Host from the HostPool"
write-output "Removing Host $AzureVMNameFQDN from the HostPool $HostPoolName"

Remove-AzWvdSessionHost -ResourceGroupName $HostPoolResourceGroupName -HostPoolName $HostPoolName -Name $AzureVMNameFQDN -Force 
 
# Execute local script on remote VM
$Script = @"
Set-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\RDInfraAgent\ -Name IsRegistered -Value 0
Set-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\RDInfraAgent\ -Name RegistrationToken -Value $($RegistrationKey.Token)
Restart-Service RDAgent
Start-service RDAgentBootLoader
"@
$Script | Out-File ".\RemoveAssignment.ps1"
 
# Execute local script on remote VM
write-output "Execute local script on remote VM"
Invoke-AzVMRunCommand -ResourceGroupName $VMResourceGroupName -VMName "$AzureVMName" -CommandId 'RunPowerShellScript' -ScriptPath '.\RemoveAssignment.ps1' 

if (!($VMStatus.Statuses.code -match 'running'))  {
    write-output "stopping VM"
    $VM | Stop-AzVM -Force
}
else {
    $VM | Restart-AzVM 
}
