#description: Unassigns a user from a personal desktop
#tags: Nerdio, Preview

<#
Notes:

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


$VMResourceGroupName = $AzureResourceGroupName
$HostPoolResourceGroupName = $HostPoolId.Split('/', [System.StringSplitOptions]::RemoveEmptyEntries)[3]
$VM = Get-AzVM -ResourceGroupName $VMResourceGroupName -Name $AzureVMName

$VMStatus = Get-AzVM -ResourceGroupName $VMResourceGroupName -Name $AzureVMName -Status
if ($VMStatus.code -notmatch 'running') {
    $VM | Start-AzVM 
}


# Generate New Registration Token
$RegistrationKey = New-AzWvdRegistrationInfo -ResourceGroupName $HostPoolResourceGroupName -HostPoolName $HostPoolName -ExpirationTime $((get-date).ToUniversalTime().AddDays(1).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'))
 
# Making AzureVMName Fully Qualified
$AzureVMNameFQDN = $vm.Tags['NMW_VM_FQDN']
 
# Removing Host from the HostPool"
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
Invoke-AzVMRunCommand -ResourceGroupName $VMResourceGroupName -VMName $AzureVMName -CommandId 'RunPowerShellScript' -ScriptPath '.\RemoveAssignment.ps1'

if ($VMStatus.code -notmatch 'running') {
    $VM | Stop-AzVM -Force
}