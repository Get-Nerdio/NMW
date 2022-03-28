#description: Get all VMs in host pool and set scale in restriction tag for X hours (default 24 hours). 
#tags: Nerdio, Preview

<# Notes:

This script will turn on all VMs in a host pool, and ensure that Nerdio does not turn the VMs off again until
X hours have passed. The number of hours is defined by the $RestrictScaleInForHours variable below, which defaults
to 24. To use a different duration for the scale in restriction, clone this script and modify the variable below.

#>

$RestrictScaleInForHours = 24

# Ensure correct subscription context is selected
Set-AzContext -SubscriptionId $AzureSubscriptionID

$Prefix = ($KeyVaultName -split '-')[0].ToUpper()

# Get hostpool resource group
$HostPoolRG = (Get-AzResource -ResourceId $HostpoolID).ResourceGroupName

# Parse the VM names from the host names
$VmNames = (Get-AzWvdSessionHost -HostPoolName $HostPoolName -ResourceGroupName $HostPoolRG).name | ForEach-Object {($_ -replace "$HostPoolName/",'' -split '\.')[0]}

$VMs = $VmNames | ForEach-Object {Get-AzVM -Name $_ -ResourceGroupName $HostPoolRG}
$RestrictUntil = (Get-Date).AddHours($RestrictScaleInForHours)
$TimeZoneId = (Get-TimeZone).id

foreach ($VM in $VMs) {
    # Set the scale in restriction tag to prevent Nerdio from turning the VMs off
    $tags["$Prefix`_SCALE_IN_RESTRICTION"] = $RestrictUntil.ToString("yyyy-MM-ddTHH") + ";$TimeZoneId"
    Set-AzResource -ResourceGroupName $vm.ResourceGroupName -Name $vm.name -ResourceType "Microsoft.Compute/VirtualMachines" -Tag $tags -Force 
}

$VMs | Start-AzVM 