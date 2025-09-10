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
    "PrivateDnsZoneResourceGroup": {
        "Description": "Resource Group of the private DNS zone for privatelink.file.core.windows.net, if the zone already exists. If the zone does not exist, the script will attempt to create it in this resource group.",
        "IsRequired": false
    },
    "PrivateDnsZoneSubscriptionId": {
        "Description": "Subscription ID of the private DNS zone for privatelink.file.core.windows.net, if the zone already exists. Defaults to the same subscription in which this script is run.",
        "IsRequired": false
    }
}
#>

$ErrorActionPreference = 'Stop'


# script body

# if the PrivateDnsZoneSubscriptionId variable is null, set it to $AzureSubscriptionId
if (-not $PrivateDnsZoneSubscriptionId) {
    $PrivateDnsZoneSubscriptionId = $AzureSubscriptionId
}

# Get the storage account
$storageAccount = Get-AzResource -ResourceId $StorageAccountResourceId
# if no storage account found, throw an error
if (-not $storageAccount) {
    throw "Storage account $StorageAccountResourceId not found"
}

# Create private link service connection
Write-Output "Creating private link service connection"
$privateLinkServiceConnection = New-AzPrivateLinkServiceConnection -Name "$($storageAccount.Name)PrivateLinkServiceConnection" -PrivateLinkServiceId $storageAccount.Id -GroupId "file"

# Get vnet
Write-Output "Getting VNet"
$vnet = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $VNetResourceGroup
# if vnet not found, throw an error
if (-not $vnet) {
    throw "VNet '$VNetName' not found in resource group '$VNetResourceGroup'"
}
# Get subnet
Write-Output "Getting subnet"
$subnet = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $VNetResourceGroup | Select-Object -ExpandProperty subnets | Where-Object Name -eq $SubnetName
# if subnet not found, throw an error
if (-not $subnet) {
    throw "Subnet '$SubnetName' not found in VNet '$VNetName' in resource group '$VNetResourceGroup'"
}

# check for private endpoint
$privateEndpoint = Get-AzPrivateEndpoint -ResourceGroupName $VNetResourceGroup -Name "$($storageAccount.Name)PrivateEndpoint" -ErrorAction SilentlyContinue
if ($privateEndpoint) {
    Write-Output "Private endpoint exists"
}
else {
# Create private endpoint
    Write-Output "Creating private endpoint and private link service connection"
    $FileServiceConnection = New-AzPrivateLinkServiceConnection -Name "$($storageAccount.Name)-serviceconnection" -PrivateLinkServiceId $storageAccount.ResourceId -GroupId 'file'
    $privateEndpoint = New-AzPrivateEndpoint -ResourceGroupName $VNetResourceGroup -Name "$($storageAccount.Name)PrivateEndpoint" -Location $storageAccount.Location -Subnet $subnet -PrivateLinkServiceConnection $privateLinkServiceConnection
}


# if subscription id of Private DNS Zone is different from $AzureSubscriptionId, change az context to $privateDnsZoneSubscriptionid
if ($PrivateDnsZoneSubscriptionid -ne $AzureSubscriptionId) {
    Write-Output "Changing Azure context to subscription $PrivateDnsZoneSubscriptionid"
    Select-AzSubscription -SubscriptionId $PrivateDnsZoneSubscriptionid
}
# check if  'privatelink.file.core.windows.net' private DNS zone exists
$PrivateDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $PrivateDnsZoneResourceGroup -Name 'privatelink.file.core.windows.net' -ErrorAction SilentlyContinue
if (-not $PrivateDnsZone) {
    Write-Output "Creating private DNS zone"
    $PrivateDnsZone = New-AzPrivateDnsZone -ResourceGroupName $PrivateDnsZoneResourceGroup -Name 'privatelink.file.core.windows.net' -EnableProxy $false
}
# link private dns zone to private endpoint
Write-Output "Linking private DNS zone to private endpoint"
New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $privatednszoneresourcegroup -ZoneName 'privatelink.file.core.windows.net' -Name "$($storageAccount.Name)PrivateDnsVirtualNetworkLink" -VirtualNetworkId $vnet.Id -EnableRegistration 

# Create private DNS zone config
$Config = New-AzPrivateDnsZoneConfig -Name 'privatelink.file.core.windows.net' -PrivateDnsZoneId $PrivateDnsZone.ResourceId

# Create private DNS zone group
Write-Output "Changing Azure context back to subscription $AzureSubscriptionId"
Select-AzSubscription -SubscriptionId $AzureSubscriptionId
Write-Output "Creating private DNS zone group"
New-AzPrivateDnsZoneGroup -ResourceGroupName $VNetResourceGroup -PrivateEndpointName $privateEndpoint.Name -Name "$($storageAccount.Name)PrivateDnsZoneGroup" -PrivateDnsZoneConfig $config
