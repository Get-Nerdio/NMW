$AzureSubscriptionId = '81332d18-a6e5-47d6-9081-a2c9041aacc0'
$AzureSubscriptionName = 'DenverNWM'
$AzureResourceGroupName = 'denver-marketplace'
$AzureRegionName = 'southcentralus'


$WVDHostVnetId = '/subscriptions/81332d18-a6e5-47d6-9081-a2c9041aacc0/resourceGroups/QADenverCore5800/providers/Microsoft.Network/virtualNetworks/NerdioVnet'

$PrivateLinkVnetName = 'NMW-PrivateLink'
$VnetAddressRange = '10.250.250.0/23'
$PrivateEndpointSubnetName = 'NMW-PrivateLink-EndpointSubnet'
$PrivateEndpointSubnetRange = '10.250.250.0/24'
$AppServiceSubnetName = 'NMW-PrivateLink-AppServiceSubnet'
$AppServiceSubnetRange = '10.250.251.0/28'


# $KeyVaultName = 'nwm-app-kv-herl7a5rkzp4u' # get from azure

# $StorageAccountNames = @('samarnewappattachstorage')

$Prefix = ($KeyVaultName -split '-')[0]
$NMWIdString = ($KeyVaultName -split '-')[3]
$NMWAppName = "$Prefix-app-$NMWIdString"
$AppServicePlanName = "$Prefix-app-plan-$NMWIdString"

<# test env only
$SqlServerName = "nwm-app-sql-$NMWIdString"
$NMWAppName = "nwm-app-$NMWIdString"
$AppServicePlanName = "nwm-app-plan-$NMWIdString"
#>

$AppServicePlan = Get-AzAppServicePlan -ResourceGroupName $AzureResourceGroupName -Name $AppServicePlanName
if ($AppServicePlan.sku.Tier -notmatch 'Premium') {
    Throw "The current NMW app service SKU does not allow private endpoints. Private endpoints can only be used with Premium app service SKUs"
    exit
}
$PrivateEndpointSubnet = New-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -AddressPrefix $PrivateEndpointSubnetRange -PrivateEndpointNetworkPoliciesFlag Disabled
$AppServiceSubnet = New-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -AddressPrefix $AppServiceSubnetRange 
$VNet = New-AzVirtualNetwork -Name $PrivateLinkVnetName -ResourceGroupName $AzureResourceGroupName -Location $AzureRegionName -AddressPrefix $VnetAddressRange -Subnet $PrivateEndpointSubnet,$AppServiceSubnet

$KeyVaultDnsZone = New-AzPrivateDnsZone -ResourceGroupName $AzureResourceGroupName -Name privatelink.vaultcore.azure.net
$SqlDnsZone = New-AzPrivateDnsZone -ResourceGroupName $AzureResourceGroupName -Name privatelink.database.azure.net
$AppServiceDnsZone = New-AzPrivateDnsZone -ResourceGroupName $AzureResourceGroupName -Name privatelink.azurewebsites.net
$StorageDnsZone = New-AzPrivateDnsZone -ResourceGroupName $AzureResourceGroupName -Name privatelink.file.core.windows.net

New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $AzureResourceGroupName -ZoneName privatelink.vaultcore.azure.net -Name nmw-vault-privatelink -VirtualNetworkId $vnet.Id
New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $AzureResourceGroupName -ZoneName privatelink.database.azure.net -Name nmw-database-privatelink -VirtualNetworkId $vnet.Id
New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $AzureResourceGroupName -ZoneName privatelink.file.core.windows.net -Name nmw-file-privatelink -VirtualNetworkId $vnet.Id
New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $AzureResourceGroupName -ZoneName privatelink.azurewebsites.net -Name nmw-appservice-privatelink -VirtualNetworkId $vnet.Id

$KeyVault = Get-AzKeyVault -VaultName $KeyVaultName -ResourceGroupName $AzureResourceGroupName 
$KvServiceConnection = New-AzPrivateLinkServiceConnection -Name "$Prefix-app-kv-$NMWIdString-serviceconnection" -PrivateLinkServiceId $KeyVault.ResourceId -GroupId vault
New-AzPrivateEndpoint -Name "$Prefix-app-kv-$NMWIdString-privateendpoint" -ResourceGroupName $AzureResourceGroupName -Location $AzureRegionName -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $KvServiceConnection
$Config = New-AzPrivateDnsZoneConfig -Name privatelink.vaultcore.azure.net -PrivateDnsZoneId $KeyVaultDnsZone.ResourceId
New-AzPrivateDnsZoneGroup -ResourceGroupName $AzureResourceGroupName -PrivateEndpointName "$Prefix-app-kv-$NMWIdString-privateendpoint" -Name "$Prefix-app-kv-$NMWIdString-dnszonegroup" -PrivateDnsZoneConfig $config

$SqlServer = Get-AzSqlServer -ResourceGroupName $AzureResourceGroupName -ServerName $SqlServerName 
$SqlServiceConnection = New-AzPrivateLinkServiceConnection -Name "$Prefix-app-sql-$NMWIdString-serviceconnection" -PrivateLinkServiceId $SqlServer.ResourceId -GroupId sqlserver
New-AzPrivateEndpoint -Name "$Prefix-app-sql-$NMWIdString-privateendpoint" -ResourceGroupName $AzureResourceGroupName -Location $AzureRegionName -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $SqlServiceConnection
$Config = New-AzPrivateDnsZoneConfig -Name 'privatelink.database.azure.net' -PrivateDnsZoneId $SqlDnsZone.ResourceId
New-AzPrivateDnsZoneGroup -ResourceGroupName $AzureResourceGroupName -PrivateEndpointName "$Prefix-app-sql-$NMWIdString-privateendpoint" -Name "$Prefix-app-sql-$NMWIdString-dnszonegroup" -PrivateDnsZoneConfig $config

$AppService = Get-AzWebApp -ResourceGroupName $AzureResourceGroupName -Name $NMWAppName 
$AppServiceConnection = New-AzPrivateLinkServiceConnection -Name "$Prefix-app-$NMWIdString-serviceconnection" -PrivateLinkServiceId $AppService.Id -GroupId sites 
New-AzPrivateEndpoint -Name "$Prefix-app-$NMWIdString-privateendpoint" -ResourceGroupName $AzureResourceGroupName -Location $AzureRegionName -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $AppServiceConnection 
$Config = New-AzPrivateDnsZoneConfig -Name 'privatelink.azurewebsites.net' -PrivateDnsZoneId $AppServiceDnsZone.ResourceId
New-AzPrivateDnsZoneGroup -ResourceGroupName $AzureResourceGroupName -PrivateEndpointName "$Prefix-app-appservice-$NMWIdString-privateendpoint" -Name "$Prefix-app-appservice-$NMWIdString-dnszonegroup" -PrivateDnsZoneConfig $config


foreach ($StorageAccountName in $StorageAccountNames) {
    $StorageAccount = Get-AzStorageAccount -ResourceGroupName $AzureResourceGroupName -Name $StorageAccountName
    $StorageServiceConnection = New-AzPrivateLinkServiceConnection -Name "$Prefix-app-files-$NMWIdString-serviceconnection" -PrivateLinkServiceId $StorageAccount.id -GroupId file
    New-AzPrivateEndpoint -Name "$Prefix-app-files-$NMWIdString-privateendpoint" -ResourceGroupName $AzureResourceGroupName -Location $AzureRegionName -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $StorageServiceConnection 
    $Config = New-AzPrivateDnsZoneConfig -Name 'privatelink.file.core.windows.net' -PrivateDnsZoneId $StorageDnsZone.ResourceId
    New-AzPrivateDnsZoneGroup -ResourceGroupName $AzureResourceGroupName -PrivateEndpointName "$Prefix-app-files-$NMWIdString-privateendpoint" -Name "$Prefix-app-files-$NMWIdString-dnszonegroup" -PrivateDnsZoneConfig $config
}


#Property array with the SubnetID
$properties = @{
  subnetResourceId = "/subscriptions/$AzureSubscriptionId/resourceGroups/$AzureResourceGroupName/providers/Microsoft.Network/virtualNetworks/$PrivateLinkVnetName/subnets/$AppServiceSubnetName"
}

#delegate app service subnet to webfarms

#Creation of the VNet integration
$vNetParams = @{
  ResourceName = "$NMWAppName/VirtualNetwork"
  Location = $AzureRegionName
  ResourceGroupName = $AzureResourceGroupName
  ResourceType = 'Microsoft.Web/sites/networkConfig'
  PropertyObject = $properties
}
New-AzResource @vNetParams -Force

New-AzDnsRecordSet -Name 