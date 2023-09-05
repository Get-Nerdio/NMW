#description: Create Azure private endpoint and private endpoint connection for Azure Files storage account and link the private DNS zone
#tags: Nerdio, Preview

<# Notes:
    This script will create a private endpoint and private endpoint connection for an Azure Files storage account and link the private DNS zone.

#>

<# Variables:
{
    "StorageAccountResourceId": {
        "Description": "Resource ID of the Azure storage account, e.g. /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/YourResourceGroup/providers/Microsoft.Storage/storageAccounts/YourStorageAccountName",
        "IsRequired": true
    },
    "VNetName": {
        "Description": "Name of the VNet where the private endpoint will be created",
        "IsRequired": true
    },
    "VNetResourceGroup": {
        "Description": "Name of the resource group where the VNet is located",
        "IsRequired": true
    },
    "SubnetName": {
        "Description": "Name of the subnet where the private endpoint will be created",
        "IsRequired": true
    },
    "PrivateDnsZoneResourceId": {
        "Description": "Resource ID of the private DNS zone, e.g. /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/YourResourceGroup/providers/Microsoft.Network/privateDnsZones/privatelink.file.core.windows.net",
        "IsRequired": true
    }
}
#>

$ErrorActionPreference = 'Stop'


# script body

# Get the storage account
$storageAccount = Get-AzResource -ResourceId $StorageAccountResourceId

# Create private link service connection
$privateLinkServiceConnection = New-AzPrivateLinkServiceConnection -Name "$($storageAccount.Name)PrivateLinkServiceConnection" -PrivateLinkServiceId $storageAccount.Id -GroupId "file"

# Get subnet
$subnet = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $VNetResourceGroup | Select-Object -ExpandProperty subnets | Where-Object Name -eq $SubnetName

# Create private endpoint
$privateEndpoint = New-AzPrivateEndpoint -ResourceGroupName $VNetResourceGroup -Name "$($storageAccount.Name)PrivateEndpoint" -Location $storageAccount.Location -Subnet $subnet -PrivateLinkServiceConnection $privateLinkServiceConnection

# Create private DNS zone config
$Config = New-AzPrivateDnsZoneConfig -Name 'privatelink.file.core.windows.net' -PrivateDnsZoneId $PrivateDnsZoneResourceId

# Create private DNS zone group
New-AzPrivateDnsZoneGroup -ResourceGroupName $VNetResourceGroup -PrivateEndpointName $privateEndpoint.Name -Name "$($storageAccount.Name)PrivateDnsZoneGroup" -PrivateDnsZoneConfig $config
