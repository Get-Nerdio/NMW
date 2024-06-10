#description: Create Azure private endpoint and private endpoint connection for Azure Files storage account and link the private DNS zone
#tags: Nerdio, Preview

<# Notes:
    This script will create a private endpoint and private endpoint connection for an Azure Files storage account and link the private DNS zone.

    This script is intended to be used in conjunction with the "Enable Private Endpoints" scripted action, to add storage accounts to the private vnet.
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
# if no storage account found, throw an error
if (-not $storageAccount) {
    throw "Storage account $StorageAccountResourceId not found"
}

# Create private link service connection
Write-Output "Creating private link service connection"
$privateLinkServiceConnection = New-AzPrivateLinkServiceConnection -Name "$($storageAccount.Name)PrivateLinkServiceConnection" -PrivateLinkServiceId $storageAccount.Id -GroupId "file"

# Get subnet
Write-Output "Getting subnet"
$subnet = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $VNetResourceGroup | Select-Object -ExpandProperty subnets | Where-Object Name -eq $SubnetName
# if subnet not found, throw an error
if (-not $subnet) {
    throw "Subnet '$SubnetName' not found in VNet '$VNetName' in resource group '$VNetResourceGroup'"
}

# check for private endpoint
$privateEndpoint = Get-AzPrivateEndpoint -ResourceGroupName $VNetResourceGroup -Name "$($storageAccount.Name)PrivateEndpoint"
if ($privateEndpoint) {
    Write-Output "Private endpoint exists"
}
else {
# Create private endpoint
    Write-Output "Creating private endpoint"
    $privateEndpoint = New-AzPrivateEndpoint -ResourceGroupName $VNetResourceGroup -Name "$($storageAccount.Name)PrivateEndpoint" -Location $storageAccount.Location -Subnet $subnet -PrivateLinkServiceConnection $privateLinkServiceConnection
}

# Create private DNS zone config
$Config = New-AzPrivateDnsZoneConfig -Name 'privatelink.file.core.windows.net' -PrivateDnsZoneId $PrivateDnsZoneResourceId

# Create private DNS zone group
New-AzPrivateDnsZoneGroup -ResourceGroupName $VNetResourceGroup -PrivateEndpointName $privateEndpoint.Name -Name "$($storageAccount.Name)PrivateDnsZoneGroup" -PrivateDnsZoneConfig $config
