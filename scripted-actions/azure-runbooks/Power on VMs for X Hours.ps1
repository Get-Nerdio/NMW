#description: Get all VMs in host pool and set scale in restriction tag for X hours (default 24 hours). 
#tags: Nerdio, Preview

<# Notes:

This script will turn on all VMs in a host pool, and ensure that Nerdio does not turn the VMs off 
again until X hours have passed. 

This script must be run from the Scripted Actions window, and you must provide the Host Pool ID
and Target OS Disk Type as parameters at runtime.

#>
<# Variables:
{
  "HostPoolId": {
    "Description": "Full Id of the host pool, e.g. /subscriptions/XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX/resourceGroups/host-pool-rg/providers/Microsoft.DesktopVirtualization/hostpools/HostPoolName",
    "IsRequired": true,
    "DefaultValue": ""
  },
  "RestrictScaleInForHours": {
    "Description": "Number of hours (from now) to prevent power off via scale-in processes",
    "IsRequired": true,
    "DefaultValue": "24"
  }
}
#>

# Ensure correct subscription context is selected
Set-AzContext -SubscriptionId $AzureSubscriptionID

$ErrorActionPreference = 'Stop'

$Prefix = ($KeyVaultName -split '-')[0].ToUpper()

# Get hostpool resource group
Write-output "Getting Host Pool Information"
$HostPool = Get-AzResource -ResourceId $HostpoolID
$HostPoolRG = $HostPool.ResourceGroupName
$HostPoolName = $Hostpool.Name

# Parse the VM names from the host names
Write-output "Getting VMs from host pool"
$VmNames = (Get-AzWvdSessionHost -HostPoolName $HostPoolName -ResourceGroupName $HostPoolRG).name | ForEach-Object {($_ -replace "$HostPoolName/",'' -split '\.')[0]}

$VMs = $VmNames | ForEach-Object {Get-AzVM -Name $_ -Status }
$RestrictUntil = (Get-Date).AddHours([int]$RestrictScaleInForHours)
$TimeZoneId = (Get-TimeZone).id

Write-output "Setting VM Tags"
foreach ($VM in $VMs) {
    $tags = $vm.tags

    # Set the scale in restriction tag to prevent Nerdio from turning the VMs off
    $tags["$Prefix`_SCALE_IN_RESTRICTION"] = $RestrictUntil.ToString("yyyy-MM-ddTHH") + ";$TimeZoneId"
    Set-AzResource -ResourceGroupName $vm.ResourceGroupName -Name $vm.name -ResourceType "Microsoft.Compute/VirtualMachines" -Tag $tags -Force 
}


write-output "Starting VMs in parallel"
$Jobs = @()

foreach ($VM in $VMs) {
    $Job = Start-Azvm -Name $vm.name -ResourceGroupName $vm.ResourceGroupName -asjob
    $Jobs += $job
}
write-output "Waiting for Start-AzVM jobs to complete"
Wait-Job -Job $Jobs

$jobs | Receive-Job