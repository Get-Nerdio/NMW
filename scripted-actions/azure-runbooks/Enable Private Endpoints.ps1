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
  "PrivateDnsKeyVaultId": {
    "Description": "Optional. Resource ID of private dns zone for keyvault. If not supplied, a new private dns zone will be created. (e.g. /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rgname/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net)",
    "IsRequired": false,
    "DefaultValue": ""
  },
  "PrivateDnsSqlId": {
    "Description": "Optional. Resource ID of private dns zone for sql. If not supplied, a new private dns zone will be created. (e.g. /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rgname/providers/Microsoft.Network/privateDnsZones/privatelink.database.windows.net)",
    "IsRequired": false,
    "DefaultValue": ""
  },
  "PrivateDnsAppServiceId": {
    "Description": "Optional. Resource ID of private dns zone for app service. If not supplied, a new private dns zone will be created. (e.g. /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rgname/providers/Microsoft.Network/privateDnsZones/privatelink.azurewebsites.net)",
    "IsRequired": false,
    "DefaultValue": ""
  },
  "PrivateDnsStorageId": {
    "Description": "Optional. Resource ID of private dns zone for storage account. If not supplied, a new private dns zone will be created. (e.g. /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rgname/providers/Microsoft.Network/privateDnsZones/privatelink.file.core.windows.net)",
    "IsRequired": false,
    "DefaultValue": ""
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
 
# Check if vnet already exists
$VNet = Get-AzVirtualNetwork -Name $PrivateLinkVnetName -ErrorAction SilentlyContinue
if ($VNet) {
    Write-Output ("VNet {0} already exists in resource group {1}." -f $vnet.Name, $vnet.ResourceGroupName)
 
    $vnetUpdated = $false
    # Check if subnet already exists
    $PrivateEndpointSubnet = Get-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -VirtualNetwork $VNet -ErrorAction SilentlyContinue
    if ($PrivateEndpointSubnet) {
        Write-Output ("Subnet {0} already exists in VNet {1}." -f $PrivateEndpointSubnet.Name, $VNet.Name)
    } else {
        Write-Output "Creating private endpoint subnet"
        $PrivateEndpointSubnet = New-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -AddressPrefix $PrivateEndpointSubnetRange -PrivateEndpointNetworkPoliciesFlag Disabled 
        $VNet | Add-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -AddressPrefix $PrivateEndpointSubnetRange -PrivateEndpointNetworkPoliciesFlag Disabled 
        $vnetUpdated = $true
    }
 
    # Check if subnet already exists
    $AppServiceSubnet = Get-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -VirtualNetwork $VNet -ErrorAction SilentlyContinue
    if ($AppServiceSubnet) {
        Write-Output ("Subnet {0} already exists in VNet {1}." -f $AppServiceSubnet.Name, $VNet.Name)
    } else {
        Write-Output "Creating app service subnet"
        $AppServiceSubnet = New-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -AddressPrefix $AppServiceSubnetRange 
        $VNet | Add-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -AddressPrefix $AppServiceSubnetRange
        $vnetUpdated = $true
    }
 
    If ($vnetUpdated){$VNet | Set-AzVirtualNetwork}
 
} else {
    Write-Output "Creating VNet"
    $PrivateEndpointSubnet = New-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -AddressPrefix $PrivateEndpointSubnetRange -PrivateEndpointNetworkPoliciesFlag Disabled 
    $AppServiceSubnet = New-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -AddressPrefix $AppServiceSubnetRange 
    $VNet = New-AzVirtualNetwork -Name $PrivateLinkVnetName -ResourceGroupName $NMWResourceGroupName -Location $NMWRegionName -AddressPrefix $VnetAddressRange -Subnet $PrivateEndpointSubnet,$AppServiceSubnet
}
 
# Create private dns zones for Key Vault if id not supplied
if ($PrivateDnsKeyVaultId) {
    $KeyVaultDnsZone = Get-AzResource -ResourceId $PrivateDnsKeyVaultId
} else {
    Write-Output "Creating Private DNS Zones for Key Vault"
    $KeyVaultDnsZone = New-AzPrivateDnsZone -ResourceGroupName $NMWResourceGroupName -Name privatelink.vaultcore.azure.net
    New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NMWResourceGroupName -ZoneName privatelink.vaultcore.azure.net -Name $Prefix-vault-privatelink -VirtualNetworkId $vnet.Id
}
 
# Create private dns zones for SQL if id not supplied
if ($PrivateDnsSqlId) {
    $SqlDnsZone = Get-AzResource -ResourceId $PrivateDnsSqlId
} else {
    Write-Output "Creating Private DNS Zones for SQL"
    $SqlDnsZone = New-AzPrivateDnsZone -ResourceGroupName $NMWResourceGroupName -Name privatelink.database.windows.net
    New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NMWResourceGroupName -ZoneName privatelink.database.windows.net -Name $Prefix-database-privatelink -VirtualNetworkId $vnet.Id
}
 
# Create private dns zones for Storage if id not supplied
if ($PrivateDnsStorageId) {
    $StorageDnsZone = Get-AzResource -ResourceId $PrivateDnsStorageId
} else {
    Write-Output "Creating Private DNS Zones for Storage"
    $StorageDnsZone = New-AzPrivateDnsZone -ResourceGroupName $NMWResourceGroupName -Name privatelink.file.core.windows.net
    New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NMWResourceGroupName -ZoneName privatelink.file.core.windows.net -Name $prefix-file-privatelink -VirtualNetworkId $vnet.Id
}
 
$VNet = Get-AzVirtualNetwork -Name $PrivateLinkVnetName -ErrorAction SilentlyContinue
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
 
Write-Output "Add VNet integration for key vault and sql"
$PrivateEndpointSubnet = Get-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -VirtualNetwork $VNet
$AppServiceSubnet = Get-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -VirtualNetwork $VNet 
 
$VNet = Get-AzVirtualNetwork -Name $PrivateLinkVnetName -ErrorAction SilentlyContinue
$VNet | Set-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -AddressPrefix $PrivateEndpointSubnetRange -ServiceEndpoint Microsoft.KeyVault,Microsoft.Sql,Microsoft.Storage | Set-AzVirtualNetwork
 
Write-Output "Delegate app service subnet to webfarms"
$VNet = Get-AzVirtualNetwork -Name $PrivateLinkVnetName -ErrorAction SilentlyContinue 
$AppSubnetDelegation = New-AzDelegation -Name "$Prefix-app-$NMWIdString-subnetdelegation" -ServiceName Microsoft.Web/serverFarms
$AppServiceSubnet = Get-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -VirtualNetwork $VNet 
$AppServiceSubnet.Delegations.Add($AppSubnetDelegation)
Set-AzVirtualNetwork -VirtualNetwork $VNet
 
Write-Output "Create app service VNet integration"
$vNetResourceGroupName = $VNet.ResourceGroupName
 
#Property array with the SubnetID
$properties = @{
    subnetResourceId = "/subscriptions/$NMWSubscriptionId/resourceGroups/$vNetResourceGroupName/providers/Microsoft.Network/virtualNetworks/$PrivateLinkVnetName/subnets/$AppServiceSubnetName"
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
} else {
    Set-AzWebApp -AppSettings $newAppSettings -Name $NMWAppName -ResourceGroupName $NMWResourceGroupName
}
 
Write-Output "Network deny rules for key vault and sql"
Add-AzKeyVaultNetworkRule -VaultName $KeyVaultName -VirtualNetworkResourceId $PrivateEndpointSubnet.id -ResourceGroupName $NMWResourceGroupName 
Update-AzKeyVaultNetworkRuleSet -VaultName $KeyVaultName -Bypass None -ResourceGroupName $NMWResourceGroupName 
Update-AzKeyVaultNetworkRuleSet -VaultName $KeyVaultName -DefaultAction Deny -ResourceGroupName $NMWResourceGroupName 
 
New-AzSqlServerVirtualNetworkRule -VirtualNetworkRuleName 'Allow private endpoint subnet' -VirtualNetworkSubnetId $PrivateEndpointSubnet.id -ServerName $Prefix-app-sql-$NMWIdString -ResourceGroupName $NMWResourceGroupName
#New-AzSqlServerVirtualNetworkRule -VirtualNetworkRuleName 'Allow app service subnet' -VirtualNetworkSubnetId $AppServiceSubnet.id -ServerName $Prefix-app-sql-$NMWIdString -ResourceGroupName $NMWResourceGroupName
Set-AzSqlServer -ServerName $SqlServerName -ResourceGroupName $NMWResourceGroupName -PublicNetworkAccess "Disabled"
 
Write-Output "Restart App Service and wait"
Restart-AzWebApp  -Name $NMWAppName -ResourceGroupName $NMWResourceGroupName
Start-Sleep -Seconds 120
 
if ($MakeAppServicePrivate -eq 'true') {
    Write-Output "Making app service private"
    # Create private dns zones for App Service if id not supplied
    if ($PrivateDnsAppServiceId) {
        $AppServiceDnsZone = Get-AzResource -ResourceId $PrivateDnsAppServiceId
    } else {
        Write-Output "Creating Private DNS Zones for App Service"
        $AppServiceDnsZone = New-AzPrivateDnsZone -ResourceGroupName $NMWResourceGroupName -Name privatelink.azurewebsites.net
        New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NMWResourceGroupName -ZoneName privatelink.azurewebsites.net -Name $prefix-appservice-privatelink -VirtualNetworkId $vnet.Id
    }
 
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
    $VNet = Get-AzVirtualNetwork -Name $PrivateLinkVnetName -ErrorAction SilentlyContinue 
    $Resource = Get-AzResource -ResourceId $PeerVnetId
    $PeerVnet = Get-AzVirtualNetwork -Name $Resource.Name -ResourceGroupName $Resource.ResourceGroupName
    Add-AzVirtualNetworkPeering -Name "$($PeerVnet.name)-$PrivateLinkVnetName" -VirtualNetwork $PeerVnet -RemoteVirtualNetworkId $vnet.id 
    Add-AzVirtualNetworkPeering -Name "$PrivateLinkVnetName-$($PeerVnet.name)" -VirtualNetwork $vnet -RemoteVirtualNetworkId $VNetId
    New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NMWResourceGroupName -ZoneName privatelink.file.core.windows.net -Name $Prefix-file-privatelink -VirtualNetworkId $PeerVnetId
    if ($MakeAppServicePrivate) {
        New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NMWResourceGroupName -ZoneName privatelink.azurewebsites.net -Name $Prefix-appservice-privatelink -VirtualNetworkId $PeerVnetId
    }
}
