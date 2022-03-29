#description: Change OS disk type from SSD<>HDD on all stopped VMs in a host pool.  Useful as a scheduled task for personal host pools using user-driven auto-scale mode.
#tags: Nerdio, Preview

<# Notes:

Change OS disk type from SSD<>HDD on all stopped VMs in a host pool.  Useful as a scheduled task 
for personal host pools using user-driven auto-scale mode.

This script must be run from the Scripted Actions window, and you must provide the Host Pool ID
and Target OS Disk Type as parameters at runtime.

By default, this script will change all disks to Premium SSD. To change to a different disk type,
modify the $TargetOSDiskType variable below to your desired disk type. 

Valid values are:
Premium_SSD
Standard_SSD 
Standard_HDD

#>

<# Variables:
{
  "HostPoolId": {
    "Description": "Full Id of the host pool, e.g. /subscriptions/XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX/resourceGroups/host-pool-rg/providers/Microsoft.DesktopVirtualization/hostpools/HostPoolName",
    "IsRequired": true,
    "DefaultValue": ""
  },
  "TargetOSDiskType": {
    "Description": "Target OS disk type for stopped VMs in the host pool. Standard_SSD, Premium_SSD, or Standard_HDD",
    "IsRequired": true,
    "DefaultValue": "Premium_SSD"
  }
}
#>

$ErrorActionPreference = 'Stop'

# Ensure correct subscription context is selected
Set-AzContext -SubscriptionId $AzureSubscriptionID

If ($TargetOSDiskType -notmatch 'Standard_SSD|Premium_SSD|Standard_HDD') {
    Throw "Provided TargetOSDiskType is not Standard_SSD, Premium_SSD, or Standard_HDD"
}

$DiskDict = @{Standard_HDD = 'Standard_LRS'; Standard_SSD = 'StandardSSD_LRS'; Premium_SSD = 'Premium_LRS' }

# Get Host Pool RG and Name
$HostPool = Get-AzResource -ResourceId $HostpoolID
$HostPoolRG = $HostPool.ResourceGroupName
$HostPoolName = $Hostpool.Name

# Parse the VM names from the host names
$VmNames = (Get-AzWvdSessionHost -HostPoolName $HostPoolName -ResourceGroupName $HostPoolRG).name | ForEach-Object {($_ -replace "$HostPoolName/",'' -split '\.')[0]}

$VMStatus = $VmNames | ForEach-Object {Get-AzVM -Name $_  -Status}

$PoweredOffVms = $VMStatus | Where-Object PowerState -eq 'VM deallocated'

if ($PoweredOffVms){
    Write-output "Retrieved powered off VMs"
}
else {
    Write-output "No powered off VMs"
}

Foreach ($VM in $PoweredOffVms) {
    $Disk = Get-AzResource -ResourceId $vm.StorageProfile.OsDisk.ManagedDisk.id
    $Disk = get-azdisk -DiskName $disk.name -ResourceGroupName $Disk.ResourceGroupName
    if ($disk.sku.name -ne $DiskDict[$targetosdisktype]){
        Write-output "Changing disk type for $($disk.name)"
        $disk.Sku = [Microsoft.Azure.Management.Compute.Models.DiskSku]::new($DiskDict[$targetosdisktype])
        $disk | Update-AzDisk
    }
    else {
        Write-output "Disk $($disk.name) is already target disk type"
    }
}


