#description: Restrict access to the sql database and keyvault used by Nerdio Manager. 
#tags: Nerdio, Preview

<# Notes:

After running this script, the Nerdio Manager site may load with status 503 "unavailable" for several seconds. 
This will not impact access to the AVD desktops.

This script will add private endpoints and service endpoints to allow the Nerdio Manager app service to communicate
with the sql database and keyvault over a private network, with no traffic routed over the public internet.
Access to the sql database and keyvault will be restricted to the private network. The MakeAppServicePrivate 
parameter can be set to 'true' to further limit access to the app service to clients on the private network or
peered network. Supplying a ResourceId for an existing network will cause that network to be peered to the new
private network. Supplying a storage account will limit access for that storage account to the new private vnet
and peered vnets.

#>

<# Variables:
{
  "PrivateLinkVnetName": {
    "Description": "New VNet for private endpoints",
    "IsRequired": true,
    "DefaultValue": "NMW-PrivateLink"
  },
  "VnetAddressRange": {
    "Description": "Address range for private endpoint vnet",
    "IsRequired": true,
    "DefaultValue": "10.250.250.0/23"
  },
  "PrivateEndpointSubnetName": {
    "Description": "Name of private endpoint subnet",
    "IsRequired": true,
    "DefaultValue": "NMW-PrivateLink-EndpointSubnet"
  },
  "PrivateEndpointSubnetRange": {
    "Description": "Address range for private endpoint subnet",
    "IsRequired": true,
    "DefaultValue": "10.250.250.0/24"
  },
  "AppServiceSubnetName": {
    "Description": "App service subnet name",
    "IsRequired": true,
    "DefaultValue": "NMW-PrivateLink-AppServiceSubnet"
  },
  "AppServiceSubnetRange": {
    "Description": "Address range for app service subnet",
    "IsRequired": true,
    "DefaultValue": "10.250.251.0/28"
  },
  "PeerVnetId": {
    "Description": "Optional. Resource ID of vnet to peer to private endpoint vnet (e.g./subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rgname/providers/Microsoft.Network/virtualNetworks/VNetName ",
    "IsRequired": false,
    "DefaultValue": ""
  },
  "StorageAccountResourceId": {
    "Description": "Optional. Storage account to be included in private endpoint subnet. Access to this storage account will be restricted to the nerdio application and peered vnets.",
    "IsRequired": false,
    "DefaultValue": ""
  },
  "MakeAppServicePrivate": {
    "Description": "Limit access to the Nerdio Manager application. If set to true, only hosts on the vnet created by this script, or on peered vnets, will be able to access the app service URL.",
    "IsRequired": false,
    "DefaultValue": "false"
  }
}
#>

$ErrorActionPreference = 'Stop'

$Prefix = ($KeyVaultName -split '-')[0]
$NMWIdString = ($KeyVaultName -split '-')[3]
$NMWAppName = "$Prefix-app-$NMWIdString"
$AppServicePlanName = "$Prefix-app-plan-$NMWIdString"
$KeyVault = Get-AzKeyVault -VaultName $KeyVaultName
$Context = Get-AzContext
$NMWSubscriptionName = $context.Subscription.Name
$NMWSubscriptionId = $context.Subscription.Id
$NMWResourceGroupName = $KeyVault.ResourceGroupName
$NMWRegionName = $KeyVault.Location
$SqlServerName = "$prefix-app-sql-$NMWIdString"

write-output "Set variables. Getting app service."
$AppServicePlan = Get-AzAppServicePlan -ResourceGroupName $NMWResourceGroupName -Name $AppServicePlanName
    
if ($MakeAppServicePrivate -eq 'true') {
    if ($AppServicePlan.sku.Tier -notmatch 'Premium') {
        Write-Output "ERROR: The current NMW app service SKU does not allow private endpoints. Private endpoints can only be used with Premium app service SKUs"
        Throw "The current NMW app service SKU does not allow private endpoints. Private endpoints can only be used with Premium app service SKUs"
        exit
    }
}

if ($AppServicePlan.sku.Tier -notmatch 'Standard|Premium')
{
    Write-Output "ERROR: The current NMW app service SKU does not VNet integration. VNet integration can only be used with Standard or Premium app service SKUs"
    Throw "The current NMW app service SKU does not VNet integration. VNet integration can only be used with Standard or Premium app service SKUs"
    exit
}

if ($StorageAccountResourceId) {
    $StorageAccount = Get-AzResource -ResourceId $StorageAccountResourceId
    if ($StorageAccount.Location -ne $NMWRegionName) {
        write-output "ERROR: Unable to create vnet integration to storage account.  Account must be in same region as the vnet."
        throw "Unable to create vnet integration to storage account.  Account must be in same region as the vnet."
        exit
    }
 
}

Write-Output "Creating VNet"
$PrivateEndpointSubnet = New-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -AddressPrefix $PrivateEndpointSubnetRange -PrivateEndpointNetworkPoliciesFlag Disabled 
$AppServiceSubnet = New-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -AddressPrefix $AppServiceSubnetRange 
$VNet = New-AzVirtualNetwork -Name $PrivateLinkVnetName -ResourceGroupName $NMWResourceGroupName -Location $NMWRegionName -AddressPrefix $VnetAddressRange -Subnet $PrivateEndpointSubnet,$AppServiceSubnet

Write-Output "Creating Private DNS Zones"
$KeyVaultDnsZone = New-AzPrivateDnsZone -ResourceGroupName $NMWResourceGroupName -Name privatelink.vaultcore.azure.net
$SqlDnsZone = New-AzPrivateDnsZone -ResourceGroupName $NMWResourceGroupName -Name privatelink.database.windows.net

New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NMWResourceGroupName -ZoneName privatelink.vaultcore.azure.net -Name $Prefix-vault-privatelink -VirtualNetworkId $vnet.Id
New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NMWResourceGroupName -ZoneName privatelink.database.windows.net -Name $Prefix-database-privatelink -VirtualNetworkId $vnet.Id

$VNet = get-AzVirtualNetwork -Name $PrivateLinkVnetName -ResourceGroupName $NMWResourceGroupName 
$PrivateEndpointSubnet = Get-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -VirtualNetwork $VNet
$AppServiceSubnet = Get-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -VirtualNetwork $VNet 

Write-Output "Configuring keyvault service connection and DNS zone"
$KeyVault = Get-AzKeyVault -VaultName $KeyVaultName -ResourceGroupName $NMWResourceGroupName 
$KvServiceConnection = New-AzPrivateLinkServiceConnection -Name "$Prefix-app-kv-$NMWIdString-serviceconnection" -PrivateLinkServiceId $KeyVault.ResourceId -GroupId vault
New-AzPrivateEndpoint -Name "$Prefix-app-kv-$NMWIdString-privateendpoint" -ResourceGroupName $NMWResourceGroupName -Location $NMWRegionName -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $KvServiceConnection
$Config = New-AzPrivateDnsZoneConfig -Name privatelink.vaultcore.azure.net -PrivateDnsZoneId $KeyVaultDnsZone.ResourceId
New-AzPrivateDnsZoneGroup -ResourceGroupName $NMWResourceGroupName -PrivateEndpointName "$Prefix-app-kv-$NMWIdString-privateendpoint" -Name "$Prefix-app-kv-$NMWIdString-dnszonegroup" -PrivateDnsZoneConfig $config

Write-Output "Configuring sql service connection and DNS zone"
$SqlServer = Get-AzSqlServer -ResourceGroupName $NMWResourceGroupName -ServerName $SqlServerName 
$SqlServiceConnection = New-AzPrivateLinkServiceConnection -Name "$Prefix-app-sql-$NMWIdString-serviceconnection" -PrivateLinkServiceId $SqlServer.ResourceId -GroupId sqlserver
New-AzPrivateEndpoint -Name "$Prefix-app-sql-$NMWIdString-privateendpoint" -ResourceGroupName $NMWResourceGroupName -Location $NMWRegionName -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $SqlServiceConnection
$Config = New-AzPrivateDnsZoneConfig -Name 'privatelink.database.azure.net' -PrivateDnsZoneId $SqlDnsZone.ResourceId
New-AzPrivateDnsZoneGroup -ResourceGroupName $NMWResourceGroupName -PrivateEndpointName "$Prefix-app-sql-$NMWIdString-privateendpoint" -Name "$Prefix-app-sql-$NMWIdString-dnszonegroup" -PrivateDnsZoneConfig $config

# Configure DNS for storage  
$StorageDnsZone = New-AzPrivateDnsZone -ResourceGroupName $NMWResourceGroupName -Name privatelink.file.core.windows.net
New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NMWResourceGroupName -ZoneName privatelink.file.core.windows.net -Name $prefix-file-privatelink -VirtualNetworkId $vnet.Id

Write-Output "Add VNet integration for key vault and sql"
$PrivateEndpointSubnet = Get-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -VirtualNetwork $VNet
$AppServiceSubnet = Get-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -VirtualNetwork $VNet 

$VNet = Get-AzVirtualNetwork -Name $PrivateLinkVnetName -ResourceGroupName $NMWResourceGroupName 
$VNet | Set-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -AddressPrefix $PrivateEndpointSubnetRange -ServiceEndpoint Microsoft.KeyVault,Microsoft.Sql | Set-AzVirtualNetwork

Write-Output "Delegate app service subnet to webfarms"
$VNet = get-AzVirtualNetwork -Name $PrivateLinkVnetName -ResourceGroupName $NMWResourceGroupName 
$AppSubnetDelegation = New-AzDelegation -Name "$Prefix-app-$NMWIdString-subnetdelegation" -ServiceName Microsoft.Web/serverFarms
$AppServiceSubnet = Get-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -VirtualNetwork $VNet 
$AppServiceSubnet.Delegations.Add($AppSubnetDelegation)
Set-AzVirtualNetwork -VirtualNetwork $VNet

Write-Output "Create app service VNet integration"

#Property array with the SubnetID
$properties = @{
    subnetResourceId = "/subscriptions/$NMWSubscriptionId/resourceGroups/$NMWResourceGroupName/providers/Microsoft.Network/virtualNetworks/$PrivateLinkVnetName/subnets/$AppServiceSubnetName"
}

$vNetParams = @{
    ResourceName = "$NMWAppName/VirtualNetwork"
    Location = $NMWRegionName
    ResourceGroupName = $NMWResourceGroupName
    ResourceType = 'Microsoft.Web/sites/networkConfig'
    PropertyObject = $properties
}
New-AzResource @vNetParams -Force

Write-Output "Add application settings to use private dns"

$app = Get-AzWebApp -Name $NMWAppName -ResourceGroupName $NMWResourceGroupName
$appSettings = $app.SiteConfig.AppSettings
$newAppSettings = @{}
ForEach ($item in $appSettings) {
    $newAppSettings[$item.Name] = $item.Value
}
$newAppSettings += @{WEBSITE_VNET_ROUTE_ALL = '1'; WEBSITE_DNS_SERVER = '168.63.129.16'}

# getting around az.websites module bug preventing app settings update
$module = Get-Module az.websites
if ($module.Version -lt '2.7.0') {
    Set-AzWebApp -AppSettings $newAppSettings -Name $NMWAppName -ResourceGroupName $NMWResourceGroupName -HttpsOnly
}
else {Set-AzWebApp -AppSettings $newAppSettings -Name $NMWAppName -ResourceGroupName $NMWResourceGroupName}


Write-Output "Network deny rules for key vault and sql"
Add-AzKeyVaultNetworkRule -VaultName $KeyVaultName -VirtualNetworkResourceId $PrivateEndpointSubnet.id -ResourceGroupName $NMWResourceGroupName 
Update-AzKeyVaultNetworkRuleSet -VaultName $KeyVaultName -Bypass None -ResourceGroupName $NMWResourceGroupName 
Update-AzKeyVaultNetworkRuleSet -VaultName $KeyVaultName -DefaultAction Deny -ResourceGroupName $NMWResourceGroupName 

New-AzSqlServerVirtualNetworkRule -VirtualNetworkRuleName 'Allow private endpoint subnet' -VirtualNetworkSubnetId $PrivateEndpointSubnet.id -ServerName $Prefix-app-sql-$NMWIdString -ResourceGroupName $NMWResourceGroupName
#New-AzSqlServerVirtualNetworkRule -VirtualNetworkRuleName 'Allow app service subnet' -VirtualNetworkSubnetId $AppServiceSubnet.id -ServerName $Prefix-app-sql-$NMWIdString -ResourceGroupName $NMWResourceGroupName
Set-AzSqlServer -ServerName $SqlServerName -ResourceGroupName $NMWResourceGroupName -PublicNetworkAccess "Disabled"

Write-Output "Restart App Service and wait"
Restart-AzWebApp  -Name $NMWAppName -ResourceGroupName $NMWResourceGroupName

Sleep 120

if ($MakeAppServicePrivate -eq 'true') {
  Write-Output "Making app service private"
  $AppServiceDnsZone = New-AzPrivateDnsZone -ResourceGroupName $NMWResourceGroupName -Name privatelink.azurewebsites.net
  New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NMWResourceGroupName -ZoneName privatelink.azurewebsites.net -Name $prefix-appservice-privatelink -VirtualNetworkId $vnet.Id
  $AppService = Get-AzWebApp -ResourceGroupName $NMWResourceGroupName -Name $NMWAppName 
  $AppServiceConnection = New-AzPrivateLinkServiceConnection -Name "$Prefix-app-$NMWIdString-serviceconnection" -PrivateLinkServiceId $AppService.Id -GroupId sites 
  New-AzPrivateEndpoint -Name "$Prefix-app-$NMWIdString-privateendpoint" -ResourceGroupName $NMWResourceGroupName -Location $NMWRegionName -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $AppServiceConnection 
  $Config = New-AzPrivateDnsZoneConfig -Name 'privatelink.azurewebsites.net' -PrivateDnsZoneId $AppServiceDnsZone.ResourceId
  New-AzPrivateDnsZoneGroup -ResourceGroupName $NMWResourceGroupName -PrivateEndpointName "$Prefix-app-$NMWIdString-privateendpoint" -Name "$Prefix-app-$NMWIdString-dnszonegroup" -PrivateDnsZoneConfig $config
}

if ($StorageAccountResourceId) {
  write-output   "Making storage account private"
    $StorageAccount = Get-AzResource -ResourceId $StorageAccountResourceId
    $StorageServiceConnection = New-AzPrivateLinkServiceConnection -Name "$Prefix-app-files-$NMWIdString-serviceconnection" -PrivateLinkServiceId $StorageAccount.id -GroupId file
    New-AzPrivateEndpoint -Name "$Prefix-app-files-$NMWIdString-privateendpoint" -ResourceGroupName $NMWResourceGroupName -Location $NMWRegionName -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $StorageServiceConnection 
    $Config = New-AzPrivateDnsZoneConfig -Name 'privatelink.file.core.windows.net' -PrivateDnsZoneId $StorageDnsZone.ResourceId
    New-AzPrivateDnsZoneGroup -ResourceGroupName $NMWResourceGroupName -PrivateEndpointName "$Prefix-app-files-$NMWIdString-privateendpoint" -Name "$Prefix-app-files-$NMWIdString-dnszonegroup" -PrivateDnsZoneConfig $config
    Add-AzStorageAccountNetworkRule -ResourceGroupName $NMWResourceGroupName -Name $StorageAccount.Name -VirtualNetworkResourceId $PrivateEndpointSubnet.id 
    Update-AzStorageAccountNetworkRuleSet -ResourceGroupName $NMWResourceGroupName -Name $StorageAccount.Name -DefaultAction Deny
    if ($PeerVnetId) {
        try {
            Add-AzStorageAccountNetworkRule -ResourceGroupName $NMWResourceGroupName -Name $StorageAccount.Name -VirtualNetworkResourceId $PeerVnetId
        }
        Catch {
            # Error here likely indicates storage account is not in a compatible region. Storage account must be in the same region as the vnet, or a paired region
            Write-Output "ERROR: Unable to create vnet integration to storage account.  Account must be in same region as the vnet, or a paired region."
        }
    }
}

if ($PeerVnetId) {
  Write-Output "Creating vnet peering"
    $VNet = Get-AzVirtualNetwork -Name $PrivateLinkVnetName -ResourceGroupName $NMWResourceGroupName 
    $Resource = Get-AzResource -ResourceId $PeerVnetId
    $PeerVnet = Get-AzVirtualNetwork -Name $Resource.Name -ResourceGroupName $Resource.ResourceGroupName
    Add-AzVirtualNetworkPeering -Name "$($PeerVnet.name)-$PrivateLinkVnetName" -VirtualNetwork $PeerVnet -RemoteVirtualNetworkId $vnet.id 
    Add-AzVirtualNetworkPeering -Name "$PrivateLinkVnetName-$($PeerVnet.name)" -VirtualNetwork $vnet -RemoteVirtualNetworkId $VNetId
    New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NMWResourceGroupName -ZoneName privatelink.file.core.windows.net -Name $Prefix-file-privatelink -VirtualNetworkId $PeerVnetId
    if ($MakeAppServicePrivate) {
        New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NMWResourceGroupName -ZoneName privatelink.azurewebsites.net -Name $Prefix-appservice-privatelink -VirtualNetworkId $PeerVnetId
    }
}
