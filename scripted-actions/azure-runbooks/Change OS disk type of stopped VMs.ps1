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


# Ensure correct subscription context is selected
Set-AzContext -SubscriptionId $AzureSubscriptionID

If ($TargetOSDiskType -notmatch 'Standard_SSD|Premium_SSD|Standard_HDD') {
    Throw "Provided TargetOSDiskType is not Standard_SSD, Premium_SSD, or Standard_HDD"
}

$Prefix = ($KeyVaultName -split '-')[0].ToUpper()

$vm = Get-AzVM -Name $AzureVMName -ResourceGroupName $AzureResourceGroupName


