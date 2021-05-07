#description: (PREVIEW) Convert session hosts to spot VM instances for reduced costs in testing environments
#tags: Nerdio, Preview
<#
Notes:
This script recreates a VM as a spot instance. This Scripted Action can be attached to the CREATE VM task under a host pool's Properties->VM Deployment
When used with a host pool, all VMs created for that host pool will be Spot VMs. This provides cost savings for testing/demo/non-production environments
in which it is acceptable for a VM to be deallocated without warning

See https://nmw.zendesk.com/hc/en-us/articles/360059485274-Scripted-Actions-Overview for more information on attaching scripted actions to VM deployments
See https://docs.microsoft.com/en-us/azure/virtual-machines/spot-vms for more information on Spot VMs and pricing

NOTE: if there is insufficient capacity for the requested Spot VM size, this script will provision the VM with standard pricing.

#>

# Adjust Variables below to alter to your preference:

##### Variables #####

# Set the desired max price for the Spot VMs.
#   Enter a dollar amount, up to 5 digits. For example, $MaxPrice = .98765 means that the VM will be deallocated once the price for a spotVM goes about $.98765 per hour.
#   -1 indicates that the VM will not be evicted based on price, only on capacity  

$MaxPrice = -1


##### Script Logic #####

$errorActionPreference = "Stop" 

Select-AzSubscription -Subscription $AzureSubscriptionName

# Get the existing VM
$VM = Get-AzVM -ResourceGroupName $AzureResourceGroupName -Name $AzureVmName 

Write-Output "INFO: Remove existing VM"
Remove-AzVM -Name $AzureVmName -ResourceGroupName $AzureResourceGroupName -Force

# Configure new VM by adding NIC and os disk from previous VM
$NewVMConfig = New-AzVMConfig  -VMName $AzureVmName -VMSize $vm.HardwareProfile.VmSize -Priority Spot -MaxPrice $MaxPrice -LicenseType $vm.LicenseType
$NewVMConfig = Add-AzVMNetworkInterface -VM $NewVMConfig -Id $vm.NetworkProfile.NetworkInterfaces[0].id
$NewVMConfig = Set-AzVMOSDisk -VM $NewVMConfig -ManagedDiskId $vm.StorageProfile.OsDisk.ManagedDisk.id -Name $vm.StorageProfile.OsDisk.Name -CreateOption Attach -StorageAccountType $vm.StorageProfile.OsDisk.ManagedDisk.StorageAccountType -Windows
#$NewVMConfig.StorageProfile.OsDisk.vhd = $null 

try {
    write-output "INFO: Creating new VM"
    $NewVM = New-AzVM -ResourceGroupName $AzureResourceGroupName -Location $vm.Location -VM $NewVMConfig -Tag $vm.Tags
}
catch {
    Write-Output $_.message 
    Write-Output $_.innerexception.message 
    Write-Output "ERROR: Error provisioning Spot VM, possibly due to capacity limitations. Attempting to re-provision as standard vm"
    try {
        $NewVMConfig = New-AzVMConfig  -VMName $AzureVmName -VMSize $vm.HardwareProfile.VmSize -LicenseType $vm.LicenseType
        $NewVMConfig = Add-AzVMNetworkInterface -VM $NewVMConfig -Id $vm.NetworkProfile.NetworkInterfaces[0].id
        $NewVMConfig = Set-AzVMOSDisk -VM $NewVMConfig -ManagedDiskId $vm.StorageProfile.OsDisk.ManagedDisk.id -Name $vm.StorageProfile.OsDisk.Name -CreateOption Attach -StorageAccountType $vm.StorageProfile.OsDisk.ManagedDisk.StorageAccountType -Windows
        $NewVM = New-AzVM -ResourceGroupName $AzureResourceGroupName -Location $vm.Location -VM $NewVMConfig -Tag $vm.Tags
    }
    catch {
        write-output "ERROR: Unable to provision VM. Removing NIC and OS disk."
        Remove-AzNetworkInterface -Name $vm.NetworkProfile.NetworkInterfaces[0].id -ResourceGroupName $AzureResourceGroupName -Force
        Remove-AzDisk -ResourceGroupName $AzureResourceGroupName -DiskName $vm.StorageProfile.OsDisk.Name -Force
    }
}
