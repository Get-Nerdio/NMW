#description: Restrict access to the sql database and keyvault used by Nerdio Manager. 
#tags: Nerdio, Preview
 
<# Notes:
 
This script will add private endpoints and service endpoints to allow the Nerdio Manager app service to communicate
with the sql database, keyvault, and automation account over a private network, with no traffic routed over the public 
internet. Access to the sql database and keyvault will be restricted to the private network. The 
MakeAppServicePrivate parameter can be set to 'true' to further limit access to the app service to clients on the 
private network or peered networks. Supplying ResourceIds for one ore more existing networks will cause those networks 
to be peered to the new private network. 

If the VNet and Subnets already exist, the existing resources will be used. If they do not exist, they will be 
created. Names for resources created by this script, such as private endpoint names, can be customized by cloning
this script and editing the variables at the top of the script.

The user cost attribution resources (app service, LAW, key vault and app insights) will also be put on the private 
network. 

If MakeSaStoragePrivate is True, the scripted actions storage account will be put on the private vnet. A hybrid 
worker VM will be created to allow the storage account to be made private while retaining Azure runbook 
functionality. This will result in increased cost for Nerdio Manager Azure resources. AVD VMs will need access to 
the storage account to run scripted actions. Use the PeerVnetIds parameter to peer the AVD vnet to the private 
endpoint vnet.
 
#>
 
<# Variables:
{
  "PrivateLinkVnetName": {
    "Description": "VNet for private endpoints. If the vnet does not exist, it will be created. If specifying an existing vnet, the vnet or its resource group must be linked to Nerdio Manager in Settings->Azure environment",
    "IsRequired": true,
    "DefaultValue": "nme-private-vnet"
  },
  "VnetAddressRange": {
    "Description": "Address range for private endpoint vnet. Not used if vnet already exists.",
    "IsRequired": false,
    "DefaultValue": "10.250.250.0/23"
  },
  "PrivateEndpointSubnetName": {
    "Description": "Name of private endpoint subnet. If the subnet does not exist, it will be created.",
    "IsRequired": true,
    "DefaultValue": "nme-endpoints-subnet"
  },
  "PrivateEndpointSubnetRange": {
    "Description": "Address range for private endpoint subnet. Not used if subnet already exists.",
    "IsRequired": false,
    "DefaultValue": "10.250.250.0/24"
  },
  "AppServiceSubnetName": {
    "Description": "App service subnet name. If the subnet does not exist, it will be created.",
    "IsRequired": true,
    "DefaultValue": "nme-app-subnet"
  },
  "AppServiceSubnetRange": {
    "Description": "Address range for app service subnet. Not used if subnet already exists.",
    "IsRequired": false,
    "DefaultValue": "10.250.251.0/28"
  },
  "ExistingDNSZonesRG": {
    "Description": "If you have private DNS zones already configured for use with the new private endpoints, specify their resource group here. This script will retrieve the existing DNS Zones and link them to the private network. Nerdio Manager needs to be linked to this RG in Settings, but can be unlinked after running this script. No changes will be made to the private DNS zones apart from linking them to the private VNet if necessary.",
    "IsRequired": false,
    "DefaultValue": ""
  },
  "ExistingDNSZonesSubId": {
    "Description": "If your existing private DNS zones are in a separate subscription from NME, specify the subscription id here. Nerdio needs to be linked to this subscription in Settings, but can be unlinked after running this script.",
    "IsRequired": false,
    "DefaultValue": ""
  },
  "MakeSaStoragePrivate": {
    "Description": "Make the scripted actions storage account private. Will create a hybrid worker VM, if one does not already exist. This will result in increased cost for Nerdio Manager Azure resources. NOTE: After this script completes, you must update Nerdio Manager to use the new hybrid worker. (Settings->Nerdio Environment->Azure runbooks scripted actions. Click `"Enabled`" and select the new hybrid worker.)",
    "IsRequired": false,
    "DefaultValue": "false"
  },
  "PeerVnetIds": {
    "Description": "Optional. Values are 'All' or comma-separated list of Azure resource IDs of VNets to peer to private endpoint VNet. If 'All' then all VNets NME manages will be peered. The VNEts or their resource groups must be linked to Nerdio Manager in Settings->Azure environment",
    "IsRequired": false,
    "DefaultValue": ""
  },
  "MakeAzureMonitorPrivate": {
    "Description": "WARNING: Because Azure Monitor uses some shared endpoints, setting up a private link even for a single resource changes the DNS configuration that affects traffic to all resources. You may not want to enable this if you have existing Log Analytics Workspaces or Insights. To minimize potential impact, this script sets ingestion and query access mode to 'Open' and disables public access on the Nerdio Manager resources only. This can be modified by cloning this script and modifying the AMPLS settings variables below.",
    "IsRequired": false,
    "DefaultValue": "false"
  },
  "MakeAppServicePrivate": {
    "Description": "WARNING: If set to true, only hosts on the VNet created by this script, or on peered VNets, will be able to access the app service URL.",
    "IsRequired": false,
    "DefaultValue": "false"
  }
}
#>
 
$ErrorActionPreference = 'Stop'

# Set variables
function Set-NmeVars {
    param(
        [Parameter(Mandatory=$true)]
        [string]$keyvaultName
    )
    Write-Verbose "Getting Nerdio Manager key vault"
    $script:NmeKeyVault = Get-AzKeyVault -VaultName $keyvaultName
    $script:NmeRg = $NmeKeyVault.ResourceGroupName
    $keyvaultTags = $NmeKeyVault.Tags
    $key = $keyvaultTags.GetEnumerator() | Where-Object { $_.Value -eq "PAAS" } | Select-Object -ExpandProperty Name
    Write-Verbose "got key $key"
    if ($key) {
        $cclwebapp = Get-AzWebApp -ResourceGroupName $NmeRg | Where-Object { $_.Tags.Keys -contains $key } | Where-Object {$_.tags[$key] -eq 'CC_DEPLOYMENT_RESOURCE'}
        if ($cclwebapp) {
            Write-Verbose "Found CCL web app"
            $script:NmeCclWebAppName = $cclwebapp.Name
        }
        Write-Verbose "Getting CCL App Insights"
        $script:NmeCclAppInsightsName = Get-AzApplicationInsights -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue | Where-Object  { $_.Tag.Keys -contains $key } | Where-Object {$_.tag[$key] -eq 'CC_DEPLOYMENT_RESOURCE'}| Select-Object -ExpandProperty Name
        if ($NmeCclAppInsightsName.count -ne 1) {
            # bug in some Az.ApplicationInsights versions
            throw "Unable to find CCL App Insights. Az.ApplicationInsights module may need to be updated to greater than v2.0.0 in the NME scripted action automation account."
        }
        Write-Verbose "NmeCclAppInsightsName is $NmeCclAppInsightsName"
        Write-Verbose "Getting CCL Log Analytics Workspace"
        $script:NmeCclLawName = Get-AzOperationalInsightsWorkspace -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue | Where-Object { $_.Tags.Keys -contains $key } | Where-Object {$_.tags[$key] -eq 'CC_DEPLOYMENT_RESOURCE'} | Select-Object -ExpandProperty Name
        Write-Verbose "NmeCclLawName is $NmeCclLawName"
        write-verbose "Getting CCL Key Vault"
        $script:NmeCclKeyVaultName = Get-AzKeyVault -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue | Where-Object { $_.Tags.Keys -contains $key } | Where-Object {$_.tags[$key] -eq 'CC_DEPLOYMENT_RESOURCE'} | Select-Object -ExpandProperty VaultName
        write-verbose "Getting CCL Storage Account"
        $script:NmeCclStorageAccountName = Get-AzStorageAccount -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue | Where-Object { $_.Tags.Keys -contains $key } | Where-Object {$_.tags[$key] -eq 'FILE_STORAGE_ACCOUNT'} | Select-Object -ExpandProperty StorageAccountName
        Write-Verbose "Getting DPS Storage Account"
        $script:NmeDpsStorageAccountName = Get-AzStorageAccount -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue | Where-Object { $_.StorageAccountName -match "^dps" } | Select-Object -ExpandProperty StorageAccountName
    }
    Write-Verbose "Getting Nerdio Manager web app"
    $webapps = Get-AzWebApp -ResourceGroupName $NmeRg 
    if ($webapps){
        $script:NmeWebApp = $webapps | Where-Object { ($_.siteconfig.appsettings | where-object name -eq "Deployment:KeyVaultName" | Select-Object -ExpandProperty value) -eq $keyvaultName }
    }
    else {
        throw "Unable to find Nerdio Manager web app"
    }
    $NmeAppInsights = Get-AzApplicationInsights -ResourceGroupName $NmeRg | Where-Object { $_.InstrumentationKey -eq ($NmeWebApp.siteconfig.appsettings | Where-Object  {$_.name -eq 'ApplicationInsights:InstrumentationKey'} | Select-Object -ExpandProperty value) }
    if ($NmeAppInsights.count -ne 1) {
        # bug in some Az.ApplicationInsights versions
        throw "Unable to find CCL App Insights. Az.ApplicationInsights module may need to be updated to greater than v2.0.0 in the NME scripted action automation account."
    }
    $script:NmeAppInsightsLAWName = ($NmeAppInsights.WorkspaceResourceId).Split("/")[-1]
    $script:NmeAppInsightsName = $NmeAppInsights.name
    $script:NmeAppServicePlanName = $NmeWebApp.ServerFarmId.Split("/")[-1]
    $script:NmeSubscriptionId = ($NmeWebApp.siteconfig.appsettings | Where-Object name -eq 'Deployment:SubscriptionId').value
    $script:NmeTagPrefix = ($NmeWebApp.siteconfig.appsettings | Where-Object name -eq 'Deployment:AzureTagPrefix').value
    $script:NmeLogAnalyticsWorkspaceId = ($NmeWebApp.siteconfig.appsettings | Where-Object name -eq 'Deployment:LogAnalyticsWorkspace').value
    $script:NmeAutomationAccountName = ($NmeWebApp.siteconfig.appsettings | Where-Object name -eq 'Deployment:AutomationAccountName').value
    $script:NmeScriptedActionsAccountName = (($NmeWebApp.siteconfig.appsettings | Where-Object name -eq 'Deployment:ScriptedActionAccount').value).Split("/")[-1]
    $script:NmeRegion = $NmeKeyVault.Location
    Write-Verbose "Getting Nerdio Manager sql server"
    $SqlServer = Get-AzSqlServer -ResourceGroupName $nmerg | ? ServerName -NotMatch '-secondary'
    if ($SqlServer.count -ne 1) {
        Throw "Unable to find NME sql server"
    }
    else {
        $script:NmeSqlServerName = $SqlServer.ServerName
    }
    $SqlSecondary = Get-AzSqlServer -ResourceGroupName $nmerg | ? ServerName -Match '-secondary'
    if ($SqlSecondary) {
        $script:NmeSqlSecondaryServerName = $SqlSecondary.ServerName
    }
    $script:NmeSqlDbName = (Get-AzSqlDatabase -ResourceGroupName $nmerg -ServerName $nmesqlserverName | Where-Object DatabaseName -ne 'master').DatabaseName
}

Set-NmeVars -keyvaultName $KeyVaultName
$Prefix = $NmeTagPrefix

# define variables for all azure resources this script will create
$KeyVaultZoneLinkName = "$Prefix-vault-privatelink"
$SqlZoneLinkName = "$Prefix-database-privatelink"
$BlobZoneLinkName = "$prefix-blob-privatelink"
$AutomationZoneLinkName = "$prefix-automation-privatelink"
$AmplScopeName = "$Prefix-app-amplscope"
$AmplRoleName = "$Prefix-app-amplrole"
$MonitorZoneLinkName = "$Prefix-monitor-privatelink"
$OpsZoneLinkName = "$Prefix-oms-privatelink"
$OdsZoneLinkName = "$Prefix-ods-privatelink"
$MonitorAgentZoneLinkName = "$Prefix-monitoragent-privatelink"
$AppServiceZoneLinkName = "$Prefix-app-appservice-privatelink"

# define variables for private endpoint names
$KvPrivateEndpointName = "$Prefix-app-kv-privateendpoint"
$SqlPrivateEndpointName = "$Prefix-app-sql-privateendpoint"
$AutomationPrivateEndpointName = "$Prefix-app-automation-privateendpoint"
$ScriptedActionsPrivateEndpointName = "$Prefix-app-scriptedactions-privateendpoint"
$ScriptedActionsStoragePrivateEndpointName = "$Prefix-app-sa-storage-privateendpoint"
$MonitorPrivateEndpointName = "$Prefix-app-monitor-privateendpoint"
$AppServicePrivateEndpointName = "$Prefix-app-appservice-privateendpoint"
$CclKvPrivateEndpointName = "$Prefix-ccl-kv-privateendpoint"
$CclAppServicePrivateEndpointName = "$Prefix-ccl-appservice-privateendpoint"
$CclStoragePrivateEndpointName = "$Prefix-ccl-storage-privateendpoint"
$DpsStoragePrivateEndpointName = "$Prefix-dps-storage-privateendpoint"

# define variables for DNS zone group names 
$KvDnsZoneGroupName = "$Prefix-app-kv-dnszonegroup"
$SqlDnsZoneGroupName = "$Prefix-app-sql-dnszonegroup"
$AutomationDnsZoneGroupName = "$Prefix-app-automation-dnszonegroup"
$ScriptedActionsDnsZoneGroupName = "$Prefix-app-scriptedactions-dnszonegroup"
$SaStoragePrivateDnsZoneGroupName = "$Prefix-app-sa-storage-dnszonegroup"
$MonitorPrivateDnsZoneGroupName = "$Prefix-app-monitor-dnszonegroup"
$AppServicePrivateDnsZoneGroupName = "$Prefix-app-appservice-dnszonegroup"
$CclKvDnsZoneGroupName = "$Prefix-ccl-kv-dnszonegroup"
$CclStoragePrivateDnsZoneGroupName = "$Prefix-ccl-storage-dnszonegroup"
$DpsStoragePrivateDnsZoneGroupName = "$Prefix-dps-storage-dnszonegroup"

# define variables for private link service connection names
$KvServiceConnectionName = "$Prefix-app-kv-serviceconnection"
$SqlServiceConnectionName = "$Prefix-app-sql-serviceconnection"
$AutomationServiceConnectionName = "$Prefix-app-automation-serviceconnection"
$ScriptedActionsServiceConnectionName = "$Prefix-app-scriptedactions-serviceconnection"
$SaStorageServiceConnectionName = "$Prefix-app-sa-storage-serviceconnection"
$MonitorServiceConnectionName = "$Prefix-app-monitor-serviceconnection"
$AppServiceServiceConnectionName = "$Prefix-app-appservice-serviceconnection"
$CclKvServiceConnectionName = "$Prefix-ccl-kv-serviceconnection"
$CclAppServiceServiceConnectionName = "$Prefix-ccl-appservice-serviceconnection"
$CclStorageServiceConnectionName = "$Prefix-ccl-storage-serviceconnection"
$DpsStorageServiceConnectionName = "$Prefix-dps-storage-serviceconnection"

# web app subnet delegation
$WebAppSubnetDelegationName = "$Prefix-app-webapp-subnetdelegation"

# define Azure monitor private link service settings
$IngestionAccessMode = 'Open'
$QueryAccessMode = 'Open'

# define variables for hybrid worker
$HybridWorkerVMName = "$Prefix-hybridworker-vm"
$HybridWorkerVMSize = 'Standard_D2s_v3'
$HybridWorkerGroupName = "$Prefix-hybridworker-group"

# Check if the web app has been restarted recently and if the script has been run before
Function Check-LastRunResults {
    # this function depends on the Set-NmeVars function, which must be run before this function
    Param()
    $MinutesAgo = 10
    $app = Get-AzWebApp -ResourceGroupName $NmeRg -Name $NmeWebApp.Name
    if ($app.LastModifiedTimeUtc -gt (get-date).AddMinutes(-$MinutesAgo).ToUniversalTime()) {
        Write-Output "Web job has been restarted recently. Checking for previous script run"
        $ThisJob = Get-AzAutomationJob -id $PSPrivateMetadata['JobId'].Guid -resourcegroupname $NmeRg -AutomationAccountName $NmeScriptedActionsAccountName 
        Invoke-WebRequest -UseBasicParsing -Uri $ThisJob.JobParameters.scriptUri -OutFile .\ThisScript.ps1
        $ThisScriptHash = Get-FileHash .\ThisScript.ps1

        $jobs = Get-AzAutomationJob -resourcegroupname $NmeRg -AutomationAccountName $NmeScriptedActionsAccountName | ? status -eq completed | ? {$_.EndTime.datetime -gt (get-date).AddMinutes(-$MinutesAgo)}
        foreach ($job in $jobs){
            $details = Get-AzAutomationJob -id $job.JobId -resourcegroupname $NmeRg -AutomationAccountName $NmeScriptedActionsAccountName 
            Invoke-WebRequest -UseBasicParsing -Uri $details.JobParameters.scriptUri -OutFile .\JobScript.ps1 
            $JobHash = Get-FileHash .\JobScript.ps1 
            if ($JobHash.hash -eq $ThisScriptHash.hash){
                Write-Output "Output of previous script run:"
                Get-AzAutomationJobOutput -Id $details.JobId -resourcegroupname $NmeRg -AutomationAccountName $NmeScriptedActionsAccountName | select summary -ExpandProperty summary
                Write-Output "App Service restarted after successfully running this script. If you need to re-run the script, please wait $($minutesago - ((get-date).AddMinutes(-$MinutesAgo).ToUniversalTime() - $app.LastModifiedTimeUtc).minutes) minutes and try again."
                Exit
            }
        }
    }
}
    
Check-LastRunResults

# set resource group for dns zones
if ($ExistingDNSZonesRG) {
    $DnsRg = $ExistingDNSZonesRG
    if ($existingDNSZonesSubId) {
        Write-Output "Setting context to subscription $existingDNSZonesSubId to retrieve existing DNS zones"
        $context = Set-AzContext -Subscription $existingDNSZonesSubId
    }
    try {
    # get DNS zones
        $KeyVaultDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name privatelink.vaultcore.azure.net -ErrorAction Stop
        $SqlDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name privatelink.database.windows.net -ErrorAction Stop
        $AutomationDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name privatelink.azure-automation.net -ErrorAction Stop
        $StorageDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name privatelink.blob.core.windows.net -ErrorAction Stop
        if ($MakeAzureMonitorPrivate -eq 'True') {
            $MonitorDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name privatelink.monitor.azure.com -ErrorAction Stop
            $OpsDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name privatelink.oms.opinsights.azure.com -ErrorAction Stop
            $OdsDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name privatelink.ods.opinsights.azure.com -ErrorAction Stop
            $MonitorAgentDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name privatelink.agentsvc.azure-automation.net -ErrorAction Stop
        }
        $AppServiceDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name privatelink.azurewebsites.net -ErrorAction Stop
        
        Write-Output "Found existing DNS zones in resource group $DnsRg"
    }
    catch {
        Write-Output "Unable to find one or more of the DNS zones in resource group $DnsRg"
        Throw $_
    }
    if ($existingDNSZonesSubId) {
        Write-Output "Setting context to subscription $NmeSubscriptionId"
        $context = Set-AzContext -Subscription $NmeSubscriptionId
    }

}
else {
    $DnsRg = $NmeRg
    # get DNS zones
    $KeyVaultDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name privatelink.vaultcore.azure.net -ErrorAction SilentlyContinue
    $SqlDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name privatelink.database.windows.net -ErrorAction SilentlyContinue
    $AutomationDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name privatelink.azure-automation.net -ErrorAction SilentlyContinue
    $StorageDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name privatelink.blob.core.windows.net -ErrorAction SilentlyContinue
    $MonitorDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name privatelink.monitor.azure.com -ErrorAction SilentlyContinue
    $OpsDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name privatelink.oms.opinsights.azure.com -ErrorAction SilentlyContinue
    $OdsDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name privatelink.ods.opinsights.azure.com -ErrorAction SilentlyContinue
    $MonitorAgentDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name privatelink.agentsvc.azure-automation.net -ErrorAction SilentlyContinue
    $AppServiceDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name privatelink.azurewebsites.net -ErrorAction SilentlyContinue
}



#### main script ####



# Check if vnet created
$VNet = Get-AzVirtualNetwork -Name $PrivateLinkVnetName -ErrorAction SilentlyContinue
if ($VNet) {
    Write-Output ("VNet {0} found in resource group {1}." -f $vnet.Name, $vnet.ResourceGroupName)
 
    $vnetUpdated = $false
    # Check if subnet created
    $PrivateEndpointSubnet = Get-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -VirtualNetwork $VNet -ErrorAction SilentlyContinue
    if ($PrivateEndpointSubnet) {
        Write-Output ("Subnet {0} found in VNet {1}." -f $PrivateEndpointSubnet.Name, $VNet.Name)
    } else {
        Write-Output "Creating private endpoint subnet"
        $PrivateEndpointSubnet = New-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -AddressPrefix $PrivateEndpointSubnetRange -PrivateEndpointNetworkPoliciesFlag Disabled 
        $VNet | Add-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -AddressPrefix $PrivateEndpointSubnetRange -PrivateEndpointNetworkPoliciesFlag Disabled 
        $vnetUpdated = $true
    }
 
    # Check if subnet created
    $AppServiceSubnet = Get-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -VirtualNetwork $VNet -ErrorAction SilentlyContinue
    if ($AppServiceSubnet) {
        Write-Output ("Subnet {0} found in VNet {1}." -f $AppServiceSubnet.Name, $VNet.Name)
    } else {
        Write-Output "Creating app service subnet"
        $AppServiceSubnet = New-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -AddressPrefix $AppServiceSubnetRange 
        $VNet | Add-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -AddressPrefix $AppServiceSubnetRange
        $vnetUpdated = $true
    }
 
    If ($vnetUpdated){$VNet | Set-AzVirtualNetwork}
 
} else {
    Write-Output "Creating VNet and subnets"
    $PrivateEndpointSubnet = New-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -AddressPrefix $PrivateEndpointSubnetRange -PrivateEndpointNetworkPoliciesFlag Disabled 
    $AppServiceSubnet = New-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -AddressPrefix $AppServiceSubnetRange 
    $VNet = New-AzVirtualNetwork -Name $PrivateLinkVnetName -ResourceGroupName $NmeRg -Location $NmeRegion -AddressPrefix $VnetAddressRange -Subnet $PrivateEndpointSubnet,$AppServiceSubnet
}

#region create DNS zones and links
# Create and link private dns zone for key vault
if ($existingDNSZonesSubId) {
    Write-Output "Setting context to subscription $existingDNSZonesSubId to create network links in DNS zones"
    $context = Set-AzContext -Subscription $existingDNSZonesSubId
}
if ($KeyVaultDnsZone) { 
    Write-Output "Private DNS Zone for Key Vault created"
    #check for linked zone
    $KeyVaultZoneLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName privatelink.vaultcore.azure.net -Name $KeyVaultZoneLinkName -ErrorAction SilentlyContinue
    if ($KeyVaultZoneLink.VirtualNetworkId -eq $vnet.id) {
        Write-Output "Private DNS Zone for Key Vault already linked to vnet"
    }
    else {
        Write-Output "Linking Private DNS Zone for Key Vault to vnet"
        $KeyVaultZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName privatelink.vaultcore.azure.net -Name $KeyVaultZoneLinkName -VirtualNetworkId $vnet.Id
    }
}
else {
    Write-Output "Creating Private DNS Zones and VNet link for Key Vault"
    $KeyVaultDnsZone = New-AzPrivateDnsZone -ResourceGroupName $NmeRg -Name privatelink.vaultcore.azure.net
    $KeyVaultZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NmeRg -ZoneName privatelink.vaultcore.azure.net -Name $KeyVaultZoneLinkName -VirtualNetworkId $vnet.Id
}

# Create and link private dns zone for sql 
if ($SqlDnsZone) {
    Write-Output "Found Private DNS Zone for SQL"
    # check for linked zone
    $SqlZoneLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName privatelink.database.windows.net -Name $SqlZoneLinkName -ErrorAction SilentlyContinue
    if ($SqlZoneLink.VirtualNetworkId -eq $vnet.id) {
        Write-Output "Private DNS Zone for SQL already linked to vnet"
    }
    else {
        Write-Output "Linking Private DNS Zone for SQL to vnet"
        $SqlZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName privatelink.database.windows.net -Name $SqlZoneLinkName -VirtualNetworkId $vnet.Id
    }
}
else {
    Write-Output "Creating Private DNS Zones and VNet link for SQL"
    $SqlDnsZone = New-AzPrivateDnsZone -ResourceGroupName $NmeRg -Name privatelink.database.windows.net
    $SqlZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NmeRg -ZoneName privatelink.database.windows.net -Name $SqlZoneLinkName -VirtualNetworkId $vnet.Id
}

if ($StorageDnsZone) {
    Write-Output "Private DNS Zone for Storage created"
    # check for linked zone
    $StorageZoneLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName privatelink.blob.core.windows.net -Name $BlobZoneLinkName -ErrorAction SilentlyContinue
    if ($StorageZoneLink.VirtualNetworkId -eq $vnet.id) {
        Write-Output "Private DNS Zone for Storage linked to vnet"
    }
    else {
        Write-Output "Linking Private DNS Zone for Storage to vnet"
        $StorageZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName privatelink.blob.core.windows.net -Name $blobzonelinkname -VirtualNetworkId $vnet.Id
    }
}
else {
    Write-Output "Creating Private DNS Zones for Storage"
    $StorageDnsZone = New-AzPrivateDnsZone -ResourceGroupName $NmeRg -Name privatelink.blob.core.windows.net
    $StorageZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NmeRg -ZoneName privatelink.blob.core.windows.net -Name $blobzonelinkname -VirtualNetworkId $vnet.Id
}

# Create and link private dns zone for automation account
if ($AutomationDnsZone) {
    Write-Output "Private DNS Zone for Automation created"
    # check for linked zone
    $AutomationZoneLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName privatelink.azure-automation.net -Name $AutomationZoneLinkName -ErrorAction SilentlyContinue
    if ($AutomationZoneLink.VirtualNetworkId -eq $vnet.id) {
        Write-Output "Private DNS Zone for Automation linked to vnet"
    }
    else {
        Write-Output "Linking Private DNS Zone for Automation to vnet"
        $AutomationZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName privatelink.azure-automation.net -Name $automationzonelinkname -VirtualNetworkId $vnet.Id
    }
}
else {
    Write-Output "Creating Private DNS Zones for Automation"
    $AutomationDnsZone = New-AzPrivateDnsZone -ResourceGroupName $NmeRg -Name privatelink.azure-automation.net
    $AutomationZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NmeRg -ZoneName privatelink.azure-automation.net -Name $automationzonelinkname -VirtualNetworkId $vnet.Id
}


# Create and link private dns zone for app service
if ($AppServiceDnsZone) {
    Write-Output "Private DNS Zone for App Service created"
    # check for linked zone
    $AppServiceZoneLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName privatelink.azurewebsites.net -Name $AppServiceZoneLinkName -ErrorAction SilentlyContinue
    if ($AppServiceZoneLink.VirtualNetworkId -eq $vnet.id) {
        Write-Output "Private DNS Zone for App Service linked to vnet"
    }
    else {
        Write-Output "Linking Private DNS Zone for App Service to vnet"
        $AppServiceZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName privatelink.azurewebsites.net -Name $AppServiceZoneLinkName -VirtualNetworkId $vnet.Id
    }
}
else {
    Write-Output "Creating Private DNS Zones for App Service"
    $AppServiceDnsZone = New-AzPrivateDnsZone -ResourceGroupName $NmeRg -Name privatelink.azurewebsites.net
    $AppServiceZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NmeRg -ZoneName privatelink.azurewebsites.net -Name $AppServiceZoneLinkName -VirtualNetworkId $vnet.Id
}

if ($MakeAzureMonitorPrivate -eq 'True') {
    # Create and link private dns zone for monitor, ops, oms, and monitor agent
    if ($MonitorDnsZone) {
        Write-Output "Private DNS Zone for Monitor created"
        # check for linked zone
        $MonitorZoneLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName privatelink.monitor.azure.com -Name $MonitorZoneLinkName -ErrorAction SilentlyContinue
        if ($MonitorZoneLink.VirtualNetworkId -eq $vnet.id) {
            Write-Output "Private DNS Zone for Monitor linked to vnet"
        }
        else {
            Write-Output "Linking Private DNS Zone for Monitor to vnet"
            $MonitorZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName privatelink.monitor.azure.com -Name $MonitorZoneLinkName -VirtualNetworkId $vnet.Id
        }
    }
    else {
        Write-Output "Creating Private DNS Zones for Monitor"
        $MonitorDnsZone = New-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name privatelink.monitor.azure.com
        $MonitorZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName privatelink.monitor.azure.com -Name $MonitorZoneLinkName -VirtualNetworkId $vnet.Id
    }
    if ($OpsDnsZone) {
        Write-Output "Private DNS Zone for Ops created"
        # check for linked zone
        $OpsZoneLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName privatelink.oms.opinsights.azure.com -Name $OpsZoneLinkName -ErrorAction SilentlyContinue
        if ($OpsZoneLink.VirtualNetworkId -eq $vnet.id) {
            Write-Output "Private DNS Zone for Ops linked to vnet"
        }
        else {
            Write-Output "Linking Private DNS Zone for Ops to vnet"
            $OpsZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName privatelink.oms.opinsights.azure.com -Name $OpsZoneLinkName -VirtualNetworkId $vnet.Id
        }
    }
    else {
        Write-Output "Creating Private DNS Zones for Ops"
        $OpsDnsZone = New-AzPrivateDnsZone -ResourceGroupName $NmeRg -Name privatelink.oms.opinsights.azure.com
        $OpsZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NmeRg -ZoneName privatelink.oms.opinsights.azure.com -Name $OpsZoneLinkName -VirtualNetworkId $vnet.Id
    }
    if ($OdsDnsZone) {
        Write-Output "Private DNS Zone for ODS created"
        # check for linked zone
        $OdsZoneLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName privatelink.ods.opinsights.azure.com -Name $OdsZoneLinkName -ErrorAction SilentlyContinue
        if ($OdsZoneLink.VirtualNetworkId -eq $vnet.id) {
            Write-Output "Private DNS Zone for ODS linked to vnet"
        }
        else {
            Write-Output "Linking Private DNS Zone for ODS to vnet"
            $OdsZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName privatelink.ods.opinsights.azure.com -Name $OdsZoneLinkName -VirtualNetworkId $vnet.Id
        }
    }
    else {
        Write-Output "Creating Private DNS Zones for ODS"
        $OdsDnsZone = New-AzPrivateDnsZone -ResourceGroupName $NmeRg -Name privatelink.ods.opinsights.azure.com
        $OdsZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NmeRg -ZoneName privatelink.ods.opinsights.azure.com -Name $OdsZoneLinkName -VirtualNetworkId $vnet.Id
    }
    if ($MonitorAgentDnsZone) {
        Write-Output "Private DNS Zone for Monitor Agent created"
        # check for linked zone
        $MonitorAgentZoneLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName privatelink.agentsvc.azure-automation.net -Name $MonitorAgentZoneLinkName -ErrorAction SilentlyContinue
        if ($MonitorAgentZoneLink.VirtualNetworkId -eq $vnet.id) {
            Write-Output "Private DNS Zone for Monitor Agent linked to vnet"
        }
        else {
            Write-Output "Linking Private DNS Zone for Monitor Agent to vnet"
            $MonitorAgentZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName privatelink.agentsvc.azure-automation.net -Name $MonitorAgentZoneLinkName -VirtualNetworkId $vnet.Id
        }
    }
    else {
        Write-Output "Creating Private DNS Zones for Monitor Agent"
        $MonitorAgentDnsZone = New-AzPrivateDnsZone -ResourceGroupName $NmeRg -Name privatelink.agentsvc.azure-automation.net
        $MonitorAgentZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NmeRg -ZoneName privatelink.agentsvc.azure-automation.net -Name $MonitorAgentZoneLinkName -VirtualNetworkId $vnet.Id
    }
}
if ($existingDNSZonesSubId) {
    Write-Output "Setting context to subscription $NmeSubscriptionId"
    $context = Set-AzContext -Subscription $NmeSubscriptionId
}
#endregion



#region create private endpoints
$VNet = Get-AzVirtualNetwork -Name $PrivateLinkVnetName -ErrorAction SilentlyContinue
$PrivateEndpointSubnet = Get-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -VirtualNetwork $VNet
$AppServiceSubnet = Get-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -VirtualNetwork $VNet 
 
# check if keyvault private endpoint created
$KvPrivateEndpoint = Get-AzPrivateEndpoint -Name "$KvPrivateEndpointName" -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue
if ($KvPrivateEndpoint) {
    Write-Output "Key Vault private endpoint created"
    
} 
else {
    Write-Output "Configuring keyvault service connection and private endpoint"
    $KvServiceConnection = New-AzPrivateLinkServiceConnection -Name $KvServiceConnectionName -PrivateLinkServiceId $NmeKeyVault.ResourceId -GroupId vault 
    $KvPrivateEndpoint = New-AzPrivateEndpoint -Name "$KvPrivateEndpointName" -ResourceGroupName $NmeRg -Location $NmeRegion -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $KvServiceConnection
}

# check if keyvault dns zone group created
$KvDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$KvPrivateEndpointName" -ErrorAction SilentlyContinue
if ($KvDnsZoneGroup) {
    Write-Output "Key Vault DNS zone group created"
} else {
    Write-Output "Configuring keyvault DNS zone group"
    $Config = New-AzPrivateDnsZoneConfig -Name privatelink.vaultcore.azure.net -PrivateDnsZoneId $KeyVaultDnsZone.ResourceId
    $KvDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$KvPrivateEndpointName" -Name "$KvDnsZoneGroupName" -PrivateDnsZoneConfig $config
}

# check if ccl key vault exists
if ($NmeCclKeyVaultName) {
    # get ccl key vault
    $NmeCclKeyVault = Get-AzKeyVault -VaultName $NmeCclKeyVaultName 
    # create if ccl key vault private endpoint created
    $CclKvPrivateEndpoint = Get-AzPrivateEndpoint -Name "$CclKvPrivateEndpointName" -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue
    if ($CclKvPrivateEndpoint) {
        Write-Output "CCL Key Vault private endpoint created"
    } 
    else {
        Write-Output "Configuring CCL keyvault service connection and private endpoint"
        $CclKvServiceConnection = New-AzPrivateLinkServiceConnection -Name $CclKvServiceConnectionName -PrivateLinkServiceId $NmeCclKeyVault.ResourceId -GroupId vault 
        $CclKvPrivateEndpoint = New-AzPrivateEndpoint -Name "$CclKvPrivateEndpointName" -ResourceGroupName $NmeRg -Location $NmeRegion -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $CclKvServiceConnection
    }
    # check if ccl keyvault dns zone group created
    $CclKvDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$CclKvPrivateEndpointName" -ErrorAction SilentlyContinue
    if ($CclKvDnsZoneGroup) {
        Write-Output "CCL Key Vault DNS zone group created"
    } else {
        Write-Output "Configuring CCL keyvault DNS zone group"
        $Config = New-AzPrivateDnsZoneConfig -Name privatelink.vaultcore.azure.net -PrivateDnsZoneId $KeyVaultDnsZone.ResourceId
        $CclKvDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$CclKvPrivateEndpointName" -Name "$CclKvDnsZoneGroupName" -PrivateDnsZoneConfig $config
    }
}

$SqlServer = Get-AzSqlServer -ResourceGroupName $NmeRg -ServerName $NmeSqlServerName

#check if sql private endpoint created
$SqlPrivateEndpoint = Get-AzPrivateEndpoint -Name "$SqlPrivateEndpointName" -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue
if ($SqlPrivateEndpoint) {
    Write-Output "SQL private endpoint created"
} 
else {
    Write-Output "Configuring sql service connection and private endpoint"
    $SqlServiceConnection = New-AzPrivateLinkServiceConnection -Name $SqlServiceConnectionName -PrivateLinkServiceId $SqlServer.ResourceId -GroupId sqlserver 
    $SqlPrivateEndpoint = New-AzPrivateEndpoint -Name "$SqlPrivateEndpointName" -ResourceGroupName $NmeRg -Location $NmeRegion -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $SqlServiceConnection 
}

# check if sql dns zone group created
$SqlDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$SqlPrivateEndpointName" -ErrorAction SilentlyContinue
if ($SqlDnsZoneGroup) {
    Write-Output "SQL DNS zone group created"
} else {
    Write-Output "Configuring sql DNS zone group"
    $Config = New-AzPrivateDnsZoneConfig -Name privatelink.database.windows.net -PrivateDnsZoneId $SqlDnsZone.ResourceId
    $SqlDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$SqlPrivateEndpointName" -Name "$SqlDnsZoneGroupName" -PrivateDnsZoneConfig $config
}


# check if automation account private endpoint is created
$AutomationPrivateEndpoint = Get-AzPrivateEndpoint -Name "$AutomationPrivateEndpointName" -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue
if ($AutomationPrivateEndpoint) {
    Write-Output "Automation private endpoint created"
} 
else {
    Write-Output "Configuring automation service connection and private endpoint"
    $NmeAutomationAccountResourceId = "/subscriptions/$NmeSubscriptionId/resourceGroups/$NmeRg/providers/Microsoft.Automation/automationAccounts/$NmeAutomationAccountName"
    $AutomationServiceConnection = New-AzPrivateLinkServiceConnection -Name $AutomationServiceConnectionName -PrivateLinkServiceId $NmeAutomationAccountResourceId -GroupId DSCAndHybridWorker 
    $AutomationPrivateEndpoint = New-AzPrivateEndpoint -Name "$AutomationPrivateEndpointName" -ResourceGroupName $NmeRg -Location $NmeRegion -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $AutomationServiceConnection 

}
# check if automation account dns zone group created
$AutomationDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$AutomationPrivateEndpointName" -ErrorAction SilentlyContinue
if ($AutomationDnsZoneGroup) {
    Write-Output "Automation DNS zone group created"
} else {
    Write-Output "Configuring automation DNS zone group"
    $Config = New-AzPrivateDnsZoneConfig -Name privatelink.azure-automation.net -PrivateDnsZoneId $AutomationDnsZone.ResourceId
    $AutomationDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$AutomationPrivateEndpointName" -Name "$K$AutomationDnsZoneGroupName" -PrivateDnsZoneConfig $config
}


# Get scripted action automation account
if ($NmeScriptedActionsAccountName) {
    # check if scripted action automation account private endpoint is created
    $ScriptedActionsPrivateEndpoint = Get-AzPrivateEndpoint -Name $ScriptedActionsPrivateEndpointName -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue
    if ($ScriptedActionsPrivateEndpoint) {
        Write-Output "Scripted actions private endpoint created"
    } 
    else {
        Write-Output "Configuring scripted actions service connection and private endpoint"
        $ScriptedActionsAccountResourceId = "/subscriptions/$NmeSubscriptionId/resourceGroups/$NmeRg/providers/Microsoft.Automation/automationAccounts/$NmeScriptedActionsAccountName"
        $ScriptedActionsServiceConnection = New-AzPrivateLinkServiceConnection -Name $ScriptedActionsServiceConnectionName -PrivateLinkServiceId $ScriptedActionsAccountResourceId -GroupId DSCAndHybridWorker 
        $ScriptedActionsPrivateEndpoint = New-AzPrivateEndpoint -Name $ScriptedActionsPrivateEndpointName -ResourceGroupName $NmeRg -Location $NmeRegion -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $ScriptedActionsServiceConnection 
    }
    # check if scripted action automation account dns zone group created
    $ScriptedActionsDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $ScriptedActionsPrivateEndpointName -ErrorAction SilentlyContinue
    if ($ScriptedActionsDnsZoneGroup) {
        Write-Output "Scripted actions DNS zone group created"
    } else {
        Write-Output "Configuring scripted actions DNS zone group"
        $Config = New-AzPrivateDnsZoneConfig -Name privatelink.azure-automation.net -PrivateDnsZoneId $AutomationDnsZone.ResourceId
        $ScriptedActionsDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $ScriptedActionsPrivateEndpointName -Name "$ScriptedActionsDnsZoneGroupName" -PrivateDnsZoneConfig $config
    }

    if ($MakeSaStoragePrivate -eq 'True') {
        # Get scripted actions storage account
        $ScriptedActionsStorageAccount = Get-AzStorageAccount -ResourceGroupName $NmeRg | Where-Object StorageAccountName -Match 'cssa'
        # check if scripted action storage account private endpoint is created
        $ScriptedActionsStoragePrivateEndpoint = Get-AzPrivateEndpoint -Name "$ScriptedActionsStoragePrivateEndpointName" -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue
        if ($ScriptedActionsStoragePrivateEndpoint) {
            Write-Output "Scripted actions storage private endpoint created"
        } 
        else {
            Write-Output "Configuring scripted actions storage service connection and private endpoint"
            $ScriptedActionsStorageAccountResourceId = "/subscriptions/$NmeSubscriptionId/resourceGroups/$NmeRg/providers/Microsoft.Storage/storageAccounts/$($ScriptedActionsStorageAccount.StorageAccountName)"
            $ScriptedActionsStorageServiceConnection = New-AzPrivateLinkServiceConnection -Name $SaStorageServiceConnectionName -PrivateLinkServiceId $ScriptedActionsStorageAccountResourceId -GroupId blob 
            $ScriptedActionsStoragePrivateEndpoint = New-AzPrivateEndpoint -Name "$ScriptedActionsStoragePrivateEndpointName" -ResourceGroupName $NmeRg -Location $NmeRegion -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $ScriptedActionsStorageServiceConnection 
        }
        # check if scripted action storage account dns zone group created
        $ScriptedActionsStorageDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$ScriptedActionsStoragePrivateEndpointName" -ErrorAction SilentlyContinue
        if ($ScriptedActionsStorageDnsZoneGroup) {
            Write-Output "Scripted actions storage DNS zone group created"
        } else {
            Write-Output "Configuring scripted actions storage DNS zone group"
            $Config = New-AzPrivateDnsZoneConfig -Name privatelink.blob.core.windows.net -PrivateDnsZoneId $StorageDnsZone.ResourceId
            $ScriptedActionsStorageDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$ScriptedActionsStoragePrivateEndpointName" -Name $SaStoragePrivateDnsZoneGroupName -PrivateDnsZoneConfig $config
        }

    }
}

if ($NmeCclStorageAccountName) {
    # Get ccl storage account
    $NmeCclStorageAccount = Get-AzStorageAccount -ResourceGroupName $NmeRg -Name $NmeCclStorageAccountName
    # check if ccl storage account private endpoint is created
    $CclStoragePrivateEndpoint = Get-AzPrivateEndpoint -Name "$CclStoragePrivateEndpointName" -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue
    if ($CclStoragePrivateEndpoint) {
        Write-Output "CCL storage private endpoint created"
    } 
    else {
        Write-Output "Configuring CCL storage service connection and private endpoint"
        $CclStorageAccountResourceId = "/subscriptions/$NmeSubscriptionId/resourceGroups/$NmeRg/providers/Microsoft.Storage/storageAccounts/$($NmeCclStorageAccount.StorageAccountName)"
        $CclStorageServiceConnection = New-AzPrivateLinkServiceConnection -Name $CclStorageServiceConnectionName -PrivateLinkServiceId $CclStorageAccountResourceId -GroupId blob 
        $CclStoragePrivateEndpoint = New-AzPrivateEndpoint -Name "$CclStoragePrivateEndpointName" -ResourceGroupName $NmeRg -Location $NmeRegion -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $CclStorageServiceConnection 
    }
    # check if ccl storage account dns zone group created
    $CclStorageDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$CclStoragePrivateEndpointName" -ErrorAction SilentlyContinue
    if ($CclStorageDnsZoneGroup) {
        Write-Output "CCL storage DNS zone group created"
    } else {
        Write-Output "Configuring CCL storage DNS zone group"
        $Config = New-AzPrivateDnsZoneConfig -Name privatelink.blob.core.windows.net -PrivateDnsZoneId $StorageDnsZone.ResourceId
        $CclStorageDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$CclStoragePrivateEndpointName" -Name $CclStoragePrivateDnsZoneGroupName -PrivateDnsZoneConfig $config
    }

}

if ($NmeDpsStorageAccountName) {
    # Get dps storage account
    $NmeDpsStorageAccount = Get-AzStorageAccount -ResourceGroupName $NmeRg -Name $NmeDpsStorageAccountName
    # check if dps storage account private endpoint is created
    $DpsStoragePrivateEndpoint = Get-AzPrivateEndpoint -Name "$DpsStoragePrivateEndpointName" -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue
    if ($DpsStoragePrivateEndpoint) {
        Write-Output "DPS storage private endpoint created"
    } 
    else {
        Write-Output "Configuring DPS storage service connection and private endpoint"
        $DpsStorageAccountResourceId = "/subscriptions/$NmeSubscriptionId/resourceGroups/$NmeRg/providers/Microsoft.Storage/storageAccounts/$($NmeDpsStorageAccount.StorageAccountName)"
        $DpsStorageServiceConnection = New-AzPrivateLinkServiceConnection -Name $DpsStorageServiceConnectionName -PrivateLinkServiceId $DpsStorageAccountResourceId -GroupId blob 
        $DpsStoragePrivateEndpoint = New-AzPrivateEndpoint -Name "$DpsStoragePrivateEndpointName" -ResourceGroupName $NmeRg -Location $NmeRegion -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $DpsStorageServiceConnection 
    }
    # check if dps storage account dns zone group created
    $DpsStorageDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$DpsStoragePrivateEndpointName" -ErrorAction SilentlyContinue
    if ($DpsStorageDnsZoneGroup) {
        Write-Output "DPS storage DNS zone group created"
    } else {
        Write-Output "Configuring DPS storage DNS zone group"
        $Config = New-AzPrivateDnsZoneConfig -Name privatelink.blob.core.windows.net -PrivateDnsZoneId $StorageDnsZone.ResourceId
        $DpsStorageDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$DpsStoragePrivateEndpointName" -Name $DpsStoragePrivateDnsZoneGroupName -PrivateDnsZoneConfig $config

    }
}
else {
    Write-Warning "Unable to find DPS storage account. Skipping private endpoint creation. You will need to manually create the private endpoint for the storage account."
}


$AppService = Get-AzWebApp -ResourceGroupName $NmeRg -Name $NmeWebApp.Name
# check if app service private endpoint is created
$AppServicePrivateEndpoint = Get-AzPrivateEndpoint -Name "$AppServicePrivateEndpointName" -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue
if ($AppServicePrivateEndpoint) {
    Write-Output "App Service private endpoint created"
} 
else {
    Write-Output "Configuring app service service connection and private endpoint"
    $AppServiceResourceId = $AppService.id
    $PrivateEndpointSubnet = Get-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -VirtualNetwork $VNet
    $AppServiceServiceConnection = New-AzPrivateLinkServiceConnection -Name $AppServiceServiceConnectionName -PrivateLinkServiceId $AppServiceResourceId -GroupId sites 
    $AppServicePrivateEndpoint = New-AzPrivateEndpoint -Name "$AppServicePrivateEndpointName" -ResourceGroupName $NmeRg -Location $NmeRegion -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $AppServiceServiceConnection 
}
# check if app service dns zone group created
$AppServiceDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$AppServicePrivateEndpointName" -ErrorAction SilentlyContinue
if ($AppServiceDnsZoneGroup) {
    Write-Output "App Service DNS zone group created"
} else {
    Write-Output "Configuring app service DNS zone group"
    $Config = New-AzPrivateDnsZoneConfig -Name privatelink.azurewebsites.net -PrivateDnsZoneId $AppServiceDnsZone.ResourceId
    $AppServiceDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$AppServicePrivateEndpointName" -Name $AppServicePrivateDnsZoneGroupName -PrivateDnsZoneConfig $config
}

$webApp = Get-AzResource -Id $NmeWebApp.id 
if ($MakeAppServicePrivate -eq 'True') {
    $webApp.Properties.publicNetworkAccess = "Disabled"
    $webApp | Set-AzResource -Force | Out-Null
}
else {
    $webApp.Properties.publicNetworkAccess = "Enabled"
    $webApp | Set-AzResource -Force | Out-Null
}

if ($NmeCclWebAppName) {
    $CclAppService = Get-AzWebApp -ResourceGroupName $NmeRg -Name $NmeCclWebAppName
    # check if ccl app service private endpoint is created
    $CclAppServicePrivateEndpoint = Get-AzPrivateEndpoint -Name "$CclAppServicePrivateEndpointName" -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue
    if ($CclAppServicePrivateEndpoint) {
        Write-Output "CCL App Service private endpoint created"
    } 
    else {
        Write-Output "Configuring CCL app service service connection and private endpoint"
        $CclAppServiceResourceId = $CclAppService.id
        $PrivateEndpointSubnet = Get-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -VirtualNetwork $VNet
        $CclAppServiceServiceConnection = New-AzPrivateLinkServiceConnection -Name $CclAppServiceServiceConnectionName -PrivateLinkServiceId $CclAppServiceResourceId -GroupId sites 
        $CclAppServicePrivateEndpoint = New-AzPrivateEndpoint -Name "$CclAppServicePrivateEndpointName" -ResourceGroupName $NmeRg -Location $NmeRegion -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $CclAppServiceServiceConnection 
    }
    # check if ccl app service dns zone group created
    $CclAppServiceDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$CclAppServicePrivateEndpointName" -ErrorAction SilentlyContinue
    if ($CclAppServiceDnsZoneGroup) {
        Write-Output "CCL App Service DNS zone group created"
    } else {
        Write-Output "Configuring CCL app service DNS zone group"
        $Config = New-AzPrivateDnsZoneConfig -Name privatelink.azurewebsites.net -PrivateDnsZoneId $AppServiceDnsZone.ResourceId
        $CclAppServiceDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$CclAppServicePrivateEndpointName" -Name $AppServicePrivateDnsZoneGroupName -PrivateDnsZoneConfig $config
    }
    $NmeCclWebApp = Get-AzWebApp -ResourceGroupName $NmeRg -Name $NmeCclWebAppName
    $cclwebapp = Get-AzResource -Id $NmeCclWebApp.id
    $cclwebapp.Properties.publicNetworkAccess = "Disabled"
    $cclwebapp | Set-AzResource -Force | Out-Null
}
#endregion

#region create azure monitor private link scope
if ($MakeAzureMonitorPrivate -eq 'True') {
    
    $AmplScopeProperties = @{
        accessModeSettings = @{
            queryAccessMode     = $QueryAccessMode; 
            ingestionAccessMode = $IngestionAccessMode
        } 
    }

    # Check if scope exists
    $AmplScope = Get-AzResource -ResourceId "/subscriptions/$NmeSubscriptionId/resourceGroups/$NmeRg/providers/Microsoft.Insights/privateLinkScopes/$AmplScopeName" -ErrorAction SilentlyContinue
    if ($AmplScope) {
        Write-Output "Azure Monitor private link scope created"
    } 
    else {
        Write-Output "Creating Azure Monitor private link scope"
        $AmplScope = New-AzResource -Location "Global" -Properties $AmplScopeProperties -ResourceName $AmplScopeName -ResourceType "Microsoft.Insights/privateLinkScopes" -ResourceGroupName $NmeRg -ApiVersion "2021-07-01-preview" -Force
    }

    # Create linked scope resources
    # Check if LAW Scope exists
    $NmeLAWName = $NmeLogAnalyticsWorkspaceId.Split("/")[-1]
    $LAWScope = Get-AzInsightsPrivateLinkScopedResource -ResourceGroupName $NmeRg -ScopeName $AmplScopeName -Name $NmeLAWName -ErrorAction SilentlyContinue
    if ($LAWScope) {
        Write-Output "Azure Monitor LAW scope created"
    } 
    else {
        Write-Output "Creating Azure Monitor LAW scope"
        $LAWScope = New-AzInsightsPrivateLinkScopedResource -LinkedResourceId $NmeLogAnalyticsWorkspaceId -ResourceGroupName $NmeRg -ScopeName $AmplScopeName -Name $NmeLAWName
    }

    # Check if App Insights Scope exists
    $AppInsightsScope = Get-AzInsightsPrivateLinkScopedResource -ResourceGroupName $NmeRg -ScopeName $AmplScopeName -Name "$NmeAppInsightsName" -ErrorAction SilentlyContinue
    if ($AppInsightsScope) {
        Write-Output "Azure Monitor App Insights scope created"
    } 
    else {
        Write-Output "Creating Azure Monitor App Insights scope"
        $AppInsights = Get-AzApplicationInsights -ResourceGroupName $NmeRg -Name "$NmeAppInsightsName"
        $AppInsightsScope = New-AzInsightsPrivateLinkScopedResource -LinkedResourceId $AppInsights.id -ResourceGroupName $NmeRg -ScopeName $AmplScopeName -Name "$NmeAppInsightsName" 
    }

    # check if app insights law scope exists
    $AppInsightsLAWScope = Get-AzInsightsPrivateLinkScopedResource -ResourceGroupName $NmeRg -ScopeName $AmplScopeName -Name $NmeAppInsightsLAWName -ErrorAction SilentlyContinue
    if ($AppInsightsLAWScope) {
        Write-Output "Azure Monitor App Insights LAW scope created"
    } 
    else {
        Write-Output "Creating Azure Monitor App Insights LAW scope"
        $AppInsightsLAW = Get-AzOperationalInsightsWorkspace -ResourceGroupName $NmeRg -Name $NmeAppInsightsLAWName
        $AppInsightsLAWScope = New-AzInsightsPrivateLinkScopedResource -LinkedResourceId $AppInsightsLAW.ResourceId -ResourceGroupName $NmeRg -ScopeName $AmplScopeName -Name $NmeAppInsightsLAWName
    }


    if ($NmeCclAppInsightsName){
        # Check if CCL Insights Scope exists
        $CCLInsightsScope = Get-AzInsightsPrivateLinkScopedResource -ResourceGroupName $NmeRg -ScopeName $AmplScopeName -Name $NmeCclAppInsightsName -ErrorAction SilentlyContinue
        if ($CCLInsightsScope) {
            Write-Output "Azure Monitor CCL Insights scope created"
        } 
        else {
            Write-Output "Creating Azure Monitor CCL Insights scope"
            # Get CCL App Insights
            $NmeCclAppInsights = Get-AzApplicationInsights -ResourceGroupName $NmeRg -Name $NmeCclAppInsightsName
            $CCLInsightsScope = New-AzInsightsPrivateLinkScopedResource -LinkedResourceId $NmeCclAppInsights.id -ResourceGroupName $NmeRg -ScopeName $AmplScopeName -Name $NmeCclAppInsightsName
        }
    }
    if ($NmeCclLawName) {
        # check if CCL LAW scope exists
        $CCLLAWScope = Get-AzInsightsPrivateLinkScopedResource -ResourceGroupName $NmeRg -ScopeName $AmplScopeName -Name $NmeCclLawName -ErrorAction SilentlyContinue
        if ($CCLLAWScope) {
            Write-Output "Azure Monitor CCL LAW scope created"
        } 
        else {
            Write-Output "Creating Azure Monitor CCL LAW scope"
            # Get CCL LAW
            $NmeCclLaw = Get-AzOperationalInsightsWorkspace -ResourceGroupName $NmeRg -Name $NmeCclLawName
            $CCLLAWScope = New-AzInsightsPrivateLinkScopedResource -LinkedResourceId $NmeCclLaw.ResourceId -ResourceGroupName $NmeRg -ScopeName $AmplScopeName -Name $NmeCclLawName
        }
    }
    # check if monitor private endpoint is created
    $MonitorPrivateEndpoint = Get-AzPrivateEndpoint -Name "$MonitorPrivateEndpointName" -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue
    if ($MonitorPrivateEndpoint) {
        Write-Output "Monitor private endpoint created"
    } 
    else {
        Write-Output "Configuring monitor service connection and private endpoint"
        $MonitorServiceConnection = New-AzPrivateLinkServiceConnection -Name $MonitorServiceConnectionName -PrivateLinkServiceId $AmplScope.ResourceId -GroupId azuremonitor 
        $MonitorPrivateEndpoint = New-AzPrivateEndpoint -Name "$MonitorPrivateEndpointName" -ResourceGroupName $NmeRg -Location $NmeRegion -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $MonitorServiceConnection 
    }

    # check if monitor dns zone group is created
    $MonitorDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$MonitorPrivateEndpointName" -ErrorAction SilentlyContinue
    if ($MonitorDnsZoneGroup) {
        Write-Output "Monitor DNS zone group created"
    } else {
        Write-Output "Configuring monitor DNS zone group"
        $Configs = @()
        # create private dns zone configs for monitor, ops, oms, and monitor agent
        $Configs += New-AzPrivateDnsZoneConfig -Name privatelink.monitor.azure.com -PrivateDnsZoneId $MonitorDnsZone.ResourceId
        $Configs += New-AzPrivateDnsZoneConfig -Name privatelink.oms.opinsights.azure.com -PrivateDnsZoneId $OpsDnsZone.ResourceId
        $Configs += New-AzPrivateDnsZoneConfig -Name privatelink.ods.opinsights.azure.com -PrivateDnsZoneId $OdsDnsZone.ResourceId
        $Configs += New-AzPrivateDnsZoneConfig -Name privatelink.agentsvc.azure-automation.net -PrivateDnsZoneId $MonitorAgentDnsZone.ResourceId
        $MonitorDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$MonitorPrivateEndpointName" -Name $MonitorPrivateDnsZoneGroupName -PrivateDnsZoneConfig $Configs
    }


}
#endregion

#region app service vnet integration
Write-Output "Add VNet service endpoints"
$VNet = Get-AzVirtualNetwork -Name $PrivateLinkVnetName 
$PrivateEndpointSubnet = Get-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -VirtualNetwork $VNet
$AppServiceSubnet = Get-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -VirtualNetwork $VNet 

$ServiceEndpoints = @('Microsoft.KeyVault', 'Microsoft.Sql', 'Microsoft.Web')
if ($MakeSaStoragePrivate -eq 'True') {
    $ServiceEndpoints += 'Microsoft.Storage'
}


if ($privateendpointsubnet.ServiceEndpoints.service){
    if (!(Compare-Object $privateendpointsubnet.ServiceEndpoints.service -DifferenceObject $serviceEndpoints -ErrorAction SilentlyContinue)) {
        Write-Output "Service endpoints created"
    } else {
        Write-Output "Adding service endpoints"
        $Vnet = $VNet | Set-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -AddressPrefix $PrivateEndpointSubnet.AddressPrefix -ServiceEndpoint $ServiceEndpoints -PrivateEndpointNetworkPoliciesFlag Enabled | Set-AzVirtualNetwork
    }
}
else {
    Write-Output "Adding service endpoints"
    $Vnet = $VNet | Set-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -AddressPrefix $PrivateEndpointSubnet.AddressPrefix -ServiceEndpoint $ServiceEndpoints -PrivateEndpointNetworkPoliciesFlag Enabled | Set-AzVirtualNetwork
}
# enable network policy
$PrivateEndpointSubnet = Get-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -VirtualNetwork $VNet
if ($PrivateEndpointSubnet.PrivateEndpointNetworkPolicies -eq 'Enabled') {
    Write-Output "Network policies enabled"
} else {
    Write-Output "Enabling network policies"
    $Vnet = $VNet | Set-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -AddressPrefix $PrivateEndpointSubnet.AddressPrefix -ServiceEndpoint $ServiceEndpoints -PrivateEndpointNetworkPoliciesFlag Enabled | Set-AzVirtualNetwork
}


$VNet = Get-AzVirtualNetwork -Name $PrivateLinkVnetName 
$AppServiceSubnet = Get-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -VirtualNetwork $VNet

# Check if subnet delegation created
$AppSubnetDelegation = Get-AzDelegation -Subnet $AppServiceSubnet -ErrorAction SilentlyContinue
if ($AppSubnetDelegation.ServiceName -eq 'Microsoft.Web/serverFarms') {
    Write-Output "App service subnet delegation created"
} 
else {
    Write-Output "Delegate app service subnet to webfarms"
    $AppServiceSubnet | Add-AzDelegation -Name $WebAppSubnetDelegationName -ServiceName "Microsoft.Web/serverFarms" | Out-Null
    $vnet = Set-AzVirtualNetwork -VirtualNetwork $VNet
}

$webApp = Get-AzResource -Id $NmeWebApp.id 
# check if endpoint integration enabled
if ($webApp.Properties.virtualNetworkSubnetId -eq $AppServiceSubnet.id) {
    Write-Output "App service VNet integration enabled"
} 
else {
    Write-Output "Enabling app service VNet integration"
    $webApp.Properties.virtualNetworkSubnetId = $AppServiceSubnet.id
    $webApp.Properties.vnetRouteAllEnabled = 'true'
    $WebApp = $webApp | Set-AzResource -Force
}

if ($NmeCclWebAppName) {
    $NmeCclWebApp = Get-AzWebApp -ResourceGroupName $NmeRg -Name $NmeCclWebAppName
    $CclWebApp = Get-AzResource -Id $NmeCclWebApp.id 
    # check if endpoint integration enabled
    if ($CclWebApp.Properties.virtualNetworkSubnetId -eq $AppServiceSubnet.id) {
        Write-Output "CCL App service VNet integration enabled"
    } 
    else {
        Write-Output "Enabling CCL app service VNet integration"
        $CclWebApp.Properties.virtualNetworkSubnetId = $AppServiceSubnet.id
        $CclWebApp.Properties.vnetRouteAllEnabled = 'true'
        $CclWebApp = $CclWebApp | Set-AzResource -Force
    }
}
# enable network policy
$AppServiceSubnet = Get-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -VirtualNetwork $VNet
$VNet = Get-AzVirtualNetwork -Name $PrivateLinkVnetName 

if ($AppServiceSubnet.PrivateEndpointNetworkPolicies -eq 'Enabled') {
    Write-Output "Network policies enabled"
} else {
    Write-Output "Enabling network policies"
    #$Vnet = $VNet | Set-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -AddressPrefix $AppServiceSubnet.addressprefix -PrivateEndpointNetworkPoliciesFlag Enabled | Set-AzVirtualNetwork
    
}
#endregion
function New-NmeHybridWorkerVm {
    [CmdletBinding()]
    Param(
        [string]$VnetName,
        [string]$SubnetName,
        [string]$VMName,
        [string]$VMSize,
        [string]$ResourceGroupName,
        [string]$HybridWorkerGroupName,
        [string]$AutomationAccountName,
        [string]$Prefix
    )

    $ErrorActionPreference = 'Stop'

    $Context = Get-AzContext

    ##### Optional Variables #####

    $AzureAutomationCertificateName = 'ScriptedActionRunAsCert'

    #Define the following parameters for the temp vm
    $vmAdminUsername = "LocalAdminUser"
    $vmAdminPassword = ConvertTo-SecureString (new-guid).guid -AsPlainText -Force
    $vmComputerName = $vmname[0..14] -join '' 
    
    #Define the following parameters for the Azure resources.
    $azureVmOsDiskName = "$VMName-osdisk"
    
    #Define the networking information.
    $azureNicName = "$VMName-nic"
    #$azurePublicIpName = "$VMName-IP"
    
    #Define the VM marketplace image details.
    $azureVmPublisherName = "MicrosoftWindowsServer"
    $azureVmOffer = "WindowsServer"
    $azureVmSkus = "2022-datacenter"
    $LicenseType = 'Windows_Client'

    $Vnet = Get-AzVirtualNetwork -Name $VnetName 

    $azureLocation = $Vnet.Location

    $AA = Get-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountName


    ##### Script Logic #####

    try {
        #Get the subnet details for the specified virtual network + subnet combination.
        Write-Output "Getting subnet details"
        $Subnet = ($Vnet).Subnets | Where-Object {$_.Name -eq $SubnetName}
        
        # Check if NIC already exists
        $azureNIC = Get-AzNetworkInterface -Name $azureNicName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        if ($azureNIC) {
            Write-Output "NIC $azureNicName created"
        }
        else {
            Write-Output "Creating hybrid worker NIC"
            $azureNIC = New-AzNetworkInterface -Name $azureNicName -ResourceGroupName $ResourceGroupName -Location $azureLocation -SubnetId $Subnet.Id 
        }

        # Check if VM already exists
        $vm = Get-AzVM -Name $VMName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        if ($vm) {
            Write-Output "Hybrid Worker VM $VMName created"
            $VM = $vm
        }
        else {
                #Store the credentials for the local admin account.
            Write-Output "Creating Hybrid Worker VM credentials"
            $vmCredential = New-Object System.Management.Automation.PSCredential ($vmAdminUsername, $vmAdminPassword)
            
            Write-Output "Creating Hybrid Worker VM"
            $VM = New-AzVMConfig -VMName $VMName -VMSize $VMSize -LicenseType $LicenseType -IdentityType SystemAssigned
            $VM = Set-AzVMOperatingSystem -VM $VM -Windows -ComputerName $vmComputerName -Credential $vmCredential -ProvisionVMAgent -EnableAutoUpdate
            $VM = Add-AzVMNetworkInterface -VM $VM -Id $azureNIC.Id
            $VM = Set-AzVMSourceImage -VM $VM -PublisherName $azureVmPublisherName -Offer $azureVmOffer -Skus $azureVmSkus -Version "latest" 
            $VM = Set-AzVMBootDiagnostic -VM $VM -Disable
            $VM = Set-AzVMOSDisk -VM $VM -StorageAccountType "StandardSSD_LRS" -Caching ReadWrite -Name $azureVmOsDiskName -CreateOption FromImage
            $VM = New-AzVM -ResourceGroupName $ResourceGroupName -Location $azureLocation -VM $VM -Verbose -ErrorAction stop
        }

        $VM = get-azvm -ResourceGroupName $ResourceGroupName -Name $VMName
        $disk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $azureVmOsDiskName -ErrorAction Continue

        # Check if hybrid worker group already exists
        try {$HybridWorkerGroup = Get-AzAutomationHybridRunbookWorkerGroup -ResourceGroupName $ResourceGroupName -AutomationAccountName $AA.AutomationAccountName -Name $HybridWorkerGroupName -ErrorAction SilentlyContinue}
        catch [System.Management.Automation.CommandNotFoundException] {
            # old version of Az.Automation module
            Throw "Command Get-AzAutomationHybridRunbookWorkerGroup not found. Please update your Az.Automation module to the latest version."
        }
        catch {
            Throw $_
        }
        if ($HybridWorkerGroup) {
            Write-Output "Hybrid worker group $HybridWorkerGroupName created"
        }
        else {
            Write-Output "Creating hybrid worker group"
            $HybridWorkerGroup = New-AzAutomationHybridRunbookWorkerGroup -ResourceGroupName $ResourceGroupName -AutomationAccountName $AA.AutomationAccountName -Name $HybridWorkerGroupName
        }

        # Check if hybrid worker already exists
        $HybridWorker = Get-AzAutomationHybridRunbookWorker -ResourceGroupName $ResourceGroupName -AutomationAccountName $AA.AutomationAccountName -HybridRunbookWorkerGroupName $HybridWorkerGroupName -ErrorAction silentlycontinue

        if ($HybridWorker) {
            Write-Output "Hybrid worker created"
        }
        else {
            Write-Output "Creating hybrid worker"
            $guid = [System.Guid]::NewGuid()
            $guidString = $guid.ToString()
            $HybridWorker = New-AzAutomationHybridRunbookWorker -AutomationAccountName $AA.AutomationAccountName -Name $guidString -HybridRunbookWorkerGroupName $HybridWorkerGroupName -VmResourceId $vm.id -ResourceGroupName $ResourceGroupName 
        }
        sleep 15

        if (($HybridWorker.ip -eq '') -or ($HybridWorker.ip -eq $null)){
            Write-Output "Installing hybrid worker extension on VM $VMName"
            write-output "Get automation hybrid service url"
            $azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
            $profileClient = New-Object -TypeName Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient -ArgumentList ($azProfile)
            $token = $profileClient.AcquireAccessToken($context.Subscription.TenantId)
            $authHeader = @{
            'Content-Type'='application/json'
            'Authorization'='Bearer ' + $token.AccessToken
            }
            $Response = Invoke-WebRequest `
                        -uri "https://$azureLocation.management.azure.com/subscriptions/$($context.subscription.id)/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/$($AA.AutomationAccountName)?api-version=2021-06-22" `
                        -Headers $authHeader `
                        -UseBasicParsing
        
            $AAProperties =  ($response.Content | ConvertFrom-Json).properties
            $AutomationHybridServiceUrl = $AAProperties.automationHybridServiceUrl
        
            $settings = @{
            "AutomationAccountURL"  = "$AutomationHybridServiceUrl"
            }
        
            Write-Output "Adding VM to hybrid worker group"
            $SetExtension = Set-AzVMExtension -ResourceGroupName $ResourceGroupName `
                            -Location $azureLocation `
                            -VMName $VMName `
                            -Name "HybridWorkerExtension" `
                            -Publisher "Microsoft.Azure.Automation.HybridWorker" `
                            -ExtensionType HybridWorkerForWindows `
                            -TypeHandlerVersion 0.1 `
                            -Settings $settings
        
            if ($SetExtension.StatusCode -eq 'OK') {
            write-output "VM successfully added to hybrid worker group"
            }
        }
        $Script = @"
        function Ensure-AutomationCertIsImported
        {
            # ------------------------------------------------------------
            # Import Azure Automation certificate if it's not imported yet
            # ------------------------------------------------------------
        
            Param (
                [Parameter(mandatory=`$true)]
                [string]`$AzureAutomationCertificateName
            )
        
            # Get the management certificate that will be used to make calls into Azure Service Management resources
            `$runAsCert = Get-AutomationCertificate -Name `$AzureAutomationCertificateName
        
            # Check if cert is already imported
            `$certStore = New-Object System.Security.Cryptography.X509Certificates.X509Store -ArgumentList "\\`$(`$env:COMPUTERNAME)\My", "LocalMachine"
            `$certStore.Open('ReadOnly') | Out-Null
            if (`$certStore.Certificates.Contains(`$runAsCert)) {
                return
            }
        
            # Generate the password
            Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue | Out-Null
            `$password = [System.Web.Security.Membership]::GeneratePassword(25, 10)
        
            # location to store temporary certificate in the Automation service host
            `$certPath = Join-Path `$env:TEMP "`$AzureAutomationCertificateName.pfx"
        
            # Save the certificate
            `$cert = `$runAsCert.Export("pfx", `$password)
            try {
                Set-Content -Value `$cert -Path `$certPath -Force -Encoding Byte | Out-Null
        
                `$securePassword = ConvertTo-SecureString `$password -AsPlainText -Force
                Import-PfxCertificate -FilePath `$certPath -CertStoreLocation Cert:\LocalMachine\My -Password `$securePassword | Out-Null
            }
            finally {
                Remove-Item -Path `$certPath -ErrorAction SilentlyContinue | Out-Null
            }
        }
        function Ensure-RequiredAzModulesInstalled
        {
            # ------------------------------------------------------------------------------
            # Install Az modules if Az.Accounts or Az.KeyVault modules are not installed yet
            # ------------------------------------------------------------------------------
        
            `$modules = Get-Module -ListAvailable
            if (!(`$modules.Name -Contains "Az.Accounts") -or !(`$modules.Name -Contains "Az.KeyVault")) {
                `$policy = Get-ExecutionPolicy -Scope CurrentUser
                try {
                    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser | Out-Null
                    `$nugetProvider = Get-PackageProvider -ListAvailable | Where-Object { `$_.Name -eq "Nuget" }
                    if (!`$nugetProvider -or (`$nugetProvider.Version | Where-Object { `$_ -ge [Version]::new("2.8.5.201") }).length -eq 0) {
                        Install-PackageProvider -Name "Nuget" -Scope AllUsers -Force | Out-Null
                    }
                    Install-Module -Name "Az" -Scope AllUsers -Repository "PSGallery" -Force | Out-Null
                }
                finally
                {
                    Set-ExecutionPolicy -ExecutionPolicy `$policy -Scope CurrentUser | Out-Null
                }
                Import-Module -Name "Az.Accounts" | Out-Null
                Import-Module -Name "Az.KeyVault" | Out-Null
            }
        }
        Ensure-AutomationCertIsImported -AzureAutomationCertificateName $AzureAutomationCertificateName 
        Ensure-RequiredAzModulesInstalled
"@

        write-output "Creating runbook to import automation certificate to hybrid worker vm"
        $Script > .\Ensure-CertAndModulesAreImported.ps1 
        $ImportRunbook = Import-AzAutomationRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $aa.AutomationAccountName -Path .\Ensure-CertAndModulesAreImported.ps1 -Type PowerShell -Name "Import-CertAndModulesToHybridRunbookWorker" -Force
        $PublishRunbook = Publish-AzAutomationRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $aa.AutomationAccountName -Name "Import-CertAndModulesToHybridRunbookWorker" 
        write-output "Importing certificate to hybrid worker vm"
        $Job = Start-AzAutomationRunbook -Name "Import-CertAndModulesToHybridRunbookWorker" -ResourceGroupName $ResourceGroupName -AutomationAccountName $aa.AutomationAccountName -RunOn $HybridWorkerGroupName

        Do {
            if ($job.status -eq 'Failed') {
            Write-Output "Job to import certificate and az modules to hybrid worker failed"
            Throw $job.Exception
            }
            if ($job.Status -eq 'Stopped') {
            write-output "Job to import certificate to hybrid worker was stopped in Azure. Please import the Nerdio manager certificate and az modules to hybrid worker vm manually"
            }
            write-output "Waiting for certificate import job to complete"
            Start-Sleep 30
            $job = Get-AzAutomationJob -Id $job.JobId -ResourceGroupName $ResourceGroupName -AutomationAccountName $aa.AutomationAccountName
        }
        while ($job.status -notmatch 'Completed|Stopped|Failed')
        
        if ($job.status -eq 'Completed'){
            Write-Output "Installed certificate and az modules on hybrid runbook worker vm"
        }


    }
    catch {
        $ErrorActionPreference = 'Continue'
        write-output "Encountered error. $_"
        write-output "Rolling back hybrid worker changes"
        $HybridWorker = Get-AzAutomationHybridRunbookWorker -ResourceGroupName $ResourceGroupName -AutomationAccountName $AA.AutomationAccountName -HybridRunbookWorkerGroupName $HybridWorkerGroupName -ErrorAction silentlycontinue
        Remove-AzAutomationRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $aa.AutomationAccountName -Name "Import-CertAndModulesToHybridRunbookWorker" -Force -ErrorAction SilentlyContinue
        if ($HybridWorker) {
            # Remove hybrid worker
            write-output "Removing hybrid worker"
            $RemoveHybridRunbookWorker = Remove-AzAutomationHybridRunbookWorker -Name $HybridWorker.Name -ResourceGroupName $ResourceGroupName -AutomationAccountName $AA.AutomationAccountName -HybridRunbookWorkerGroupName $HybridWorkerGroupName -ErrorAction Continue
        }

        if ($HybridWorkerGroup){
            # remove hybrid worker group
            write-output "Removing hybrid worker group"
            $RemoveWorkerGroup = Remove-AzAutomationHybridRunbookWorkerGroup -Name $HybridWorkerGroup.name -ResourceGroupName $ResourceGroupName -AutomationAccountName $AA.AutomationAccountName -ErrorAction Continue
        }

        if ($VM) {
            write-output "removing VM $VMName"
            Remove-AzVM -Name $VMName -ResourceGroupName $ResourceGroupName  -Force -ErrorAction Continue
        }

        if ($azureNIC) {
            write-output "removing NIC $azureNicName"
            Remove-AzNetworkInterface -Name $azureNicName -ResourceGroupName $ResourceGroupName -Force -ErrorAction Continue
        }

        if ($disk) {
            write-output "Removing disk"
            Remove-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $azureVmOsDiskName -Force -ErrorAction Continue
        }
        Write-Output "Unable to create hybrid worker vm. May need to create manually. See exception for details"
        Throw $_ 
    }

}

if ($MakeSaStoragePrivate -eq 'True') {
    # check if scripted action automation account has hybrid worker group
    $HybridWorkerGroup = Get-AzAutomationHybridWorkerGroup -ResourceGroupName $NmeRg -AutomationAccountName $NmeScriptedActionsAccountName 
    if ($HybridWorkerGroup) {
        Write-Output "Scripted actions automation account has hybrid worker group. Skipping creation of hybrid worker group and VM."
    }
    else {
        Write-Output "Creating hybrid worker VM for scripted actions automation account"
        Try {
            New-NmeHybridWorkerVm -VnetName $PrivateLinkVnetName -SubnetName $PrivateEndpointSubnetName -VMName $HybridWorkerVMName -VMSize $HybridWorkerVMSize -ResourceGroupName $NmeRg -HybridWorkerGroupName $HybridWorkerGroupName -AutomationAccountName $NmeScriptedActionsAccountName -Prefix $Prefix -ErrorAction Stop
            $NewHybridWorker = $true

        }
        catch {
            Write-Output "Unable to create hybrid worker VM for scripted actions automation account. See exception for details"
            Throw $_
        }
    }
}


Write-Output "Check network deny rules for key vault and sql"
$NmeKeyVault = Get-AzKeyVault -ResourceGroupName $NmeRg -VaultName $KeyVaultName
# check if deny rule for key vault exists
if (($NmeKeyVault.NetworkAcls.DefaultAction -eq 'Deny') -and ($NmeKeyVault.PublicNetworkAccess -eq 'Disabled')) {
    Write-Output "Key vault public access disabled"
}
else {
    Write-Output "Disabling key vault public access"
    Add-AzKeyVaultNetworkRule -VaultName $NmeKeyVault.VaultName -VirtualNetworkResourceId $PrivateEndpointSubnet.id -ResourceGroupName $NmeRg 
    Update-AzKeyVaultNetworkRuleSet -VaultName $NmeKeyVault.VaultName -Bypass None -ResourceGroupName $NmeRg
    update-AzKeyVaultNetworkRuleSet -VaultName $NmeKeyVault.VaultName -DefaultAction Deny -ResourceGroupName $NmeRg
    Update-AzKeyVault -ResourceGroupName $NmeRg -VaultName $NmeKeyVault.VaultName -PublicNetworkAccess 'Disabled'
}
if ($NmeCclKeyVaultName) {
    $NmeCclKeyVault = Get-AzKeyVault -ResourceGroupName $NmeRg -VaultName $NmeCclKeyVaultName
    # check if deny rule for key vault exists
    if (($NmeCclKeyVault.NetworkAcls.DefaultAction -eq 'Deny') -and ($NmeCclKeyVault.PublicNetworkAccess -eq 'Disabled')) {
        Write-Output "CCL Key vault public access disabled"
    }
    else {
        Write-Output "Disabling CCL key vault public access"
        Add-AzKeyVaultNetworkRule -VaultName $NmeCclKeyVault.VaultName -VirtualNetworkResourceId $PrivateEndpointSubnet.id -ResourceGroupName $NmeRg 
        Update-AzKeyVaultNetworkRuleSet -VaultName $NmeCclKeyVault.VaultName -Bypass None -ResourceGroupName $NmeRg
        update-AzKeyVaultNetworkRuleSet -VaultName $NmeCclKeyVault.VaultName -DefaultAction Deny -ResourceGroupName $NmeRg
        Update-AzKeyVault -ResourceGroupName $NmeRg -VaultName $NmeCclKeyVault.VaultName -PublicNetworkAccess 'Disabled'
    }
}

# check if deny rule for sql exists
$SqlServer = Get-AzSqlServer -ResourceGroupName $NmeRg -ServerName $NmeSqlServerName
$ServerRules = Get-AzSqlServerVirtualNetworkRule -ServerName $NmeSqlServerName -ResourceGroupName $NmeRg 
if (($ServerRules.VirtualNetworkSubnetId -contains $PrivateEndpointSubnet.id) -and ($SqlServer.PublicNetworkAccess -eq 'Disabled')) {
    Write-Output "SQL public access disabled"
}
else {
    Write-Output "Disabling SQL public access"
    if ($ServerRules.VirtualNetworkSubnetId -notcontains $PrivateEndpointSubnet.id){
        $PrivateEndpointRule = New-AzSqlServerVirtualNetworkRule -VirtualNetworkRuleName 'Allow private endpoint subnet' -VirtualNetworkSubnetId $PrivateEndpointSubnet.id -ServerName $NmeSqlServerName -ResourceGroupName $NmeRg
    }
    # New-AzSqlServerVirtualNetworkRule -VirtualNetworkRuleName 'Allow app service subnet' -VirtualNetworkSubnetId $AppServiceSubnet.id -ServerName $NmeSqlServerName -ResourceGroupName $NmeRg
    if ($SqlServer.PublicNetworkAccess -eq 'Enabled'){
        $DenyPublicSql = Set-AzSqlServer -ServerName $NmeSqlServerName -ResourceGroupName $NmeRg -PublicNetworkAccess "Disabled"
    }
}

if ($MakeSaStoragePrivate -eq 'True') {
    # check if deny rule for storage exists
    $StorageAccount = Get-AzStorageAccount -ResourceGroupName $NmeRg | Where-Object StorageAccountName -Match 'cssa'
    if ($StorageAccount.PublicNetworkAccess -eq 'Disabled') {
        Write-Output "Storage public access is disabled"
    }
    else {
        Write-Output "Disabling storage public access"
        Set-AzStorageAccount -PublicNetworkAccess Disabled -ResourceGroupName $NmeRg -Name $StorageAccount.StorageAccountName | Out-Null
    }
}

# make ccl storage account private
if ($NmeCclStorageAccountName) {
    $NmeCclStorageAccount = Get-AzStorageAccount -ResourceGroupName $NmeRg -Name $NmeCclStorageAccountName
    if ($NmeCclStorageAccount.PublicNetworkAccess -eq 'Disabled') {
        Write-Output "CCL Storage public access is disabled"
    }
    else {
        Write-Output "Disabling CCL storage public access"
        Set-AzStorageAccount -PublicNetworkAccess Disabled -ResourceGroupName $NmeRg -Name $NmeCclStorageAccount.StorageAccountName | Out-Null
    }
}

# make dps storage account private
if ($NmeDpsStorageAccountName) {
    $NmeDpsStorageAccount = Get-AzStorageAccount -ResourceGroupName $NmeRg -Name $NmeDpsStorageAccountName
    if ($NmeDpsStorageAccount.PublicNetworkAccess -eq 'Disabled') {
        Write-Output "DPS Storage public access is disabled"
    }
    else {
        Write-Output "Disabling DPS storage public access"
        Set-AzStorageAccount -PublicNetworkAccess Disabled -ResourceGroupName $NmeRg -Name $NmeDpsStorageAccount.StorageAccountName | Out-Null
    }
}

if ($PeerVnetIds) {
    Write-Output "Peering vnets" 
    $VNet = Get-AzVirtualNetwork -Name $PrivateLinkVnetName 
    if ($PeerVnetIds -eq 'All') {
        $VnetIds = Get-AzVirtualNetwork | ? {if ($_.tag){$True}}| Where-Object {$_.tag["$Prefix`_OBJECT_TYPE"] -eq 'LINKED_NETWORK'} -ErrorAction SilentlyContinue | Where-Object id -ne $vnet.id | Select-Object -ExpandProperty Id
    }
    else {
        $VnetIds = $PeerVnetIds -split ','
    }
    foreach ($id in $VnetIds) {
        $VNet = Get-AzVirtualNetwork -Name $PrivateLinkVnetName -ErrorAction SilentlyContinue 
        $Resource = Get-AzResource -ResourceId $id
        $PeerVnet = Get-AzVirtualNetwork -Name $Resource.Name -ResourceGroupName $Resource.ResourceGroupName
        # check if inbound peering exists
        $InboundPeering = Get-AzVirtualNetworkPeering -Name "$($PeerVnet.name)-$PrivateLinkVnetName" -VirtualNetworkName $PeerVnet.Name -ResourceGroupName $Resource.ResourceGroupName -ErrorAction SilentlyContinue
        if ($InboundPeering) {
            Write-Output "Inbound peering exists"
        }
        else {
            Write-Output "Creating inbound peering"
            $InboundPeering = Add-AzVirtualNetworkPeering -Name "$($PeerVnet.name)-$PrivateLinkVnetName" -VirtualNetwork $PeerVnet -RemoteVirtualNetworkId $vnet.id 
        }
        # check if outbound peering exists
        $OutboundPeering = Get-AzVirtualNetworkPeering -Name "$PrivateLinkVnetName-$($PeerVnet.name)" -VirtualNetworkName $vnet.Name -ResourceGroupName $Vnet.ResourceGroupName -ErrorAction SilentlyContinue
        if ($OutboundPeering) {
            Write-Output "Outbound peering exists"
        }
        else {
            Write-Output "Creating outbound peering"
            $OutboundPeering = Add-AzVirtualNetworkPeering -Name "$PrivateLinkVnetName-$($PeerVnet.name)" -VirtualNetwork $vnet -RemoteVirtualNetworkId $id
        }
        # allow peer vnet to access storage account
        # check if file private link exists
        $FilePrivateLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NmeRG -ZoneName privatelink.blob.core.windows.net -Name $($PeerVnet.name +  '-blob-privatelink') -ErrorAction SilentlyContinue
        if ($FilePrivateLink) {
            Write-Output "File private link exists"
        }
        else {
            Write-Output "Creating file private link"
            $FilePrivateLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NmeRG -ZoneName privatelink.blob.core.windows.net -Name $($PeerVnet.name +  '-blob-privatelink') -VirtualNetworkId $id
        }
        if ($MakeAppServicePrivate -eq 'True') {
            # allow peer vnet to access app service
            # check if app service private link exists
            $AppServicePrivateLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NmeRG -ZoneName privatelink.azurewebsites.net -Name $($PeerVnet.name + '-appservice-privatelink') -ErrorAction SilentlyContinue
            if ($AppServicePrivateLink) {
                Write-Output "App service private link exists"
            }
            else {
                Write-Output "Creating app service private link"
                $AppServicePrivateLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NmeRG -ZoneName privatelink.azurewebsites.net -Name $($PeerVnet.name + '-appservice-privatelink') -VirtualNetworkId $id
            }
        }
    }
}

if ($NewHybridWorker) {
    Write-Output "Hybrid worker group '$HybridWorkerGroupName' has been created. Please update Nerdio Manager to use the new hybrid worker. (Settings->Nerdio Environment->Azure runbooks scripted actions. Click `"Enabled`" and select the new hybrid worker.)"
    Write-Warning "Hybrid worker group '$HybridWorkerGroupName' has been created. Please update Nerdio Manager to use the new hybrid worker. (Settings->Nerdio Environment->Azure runbooks scripted actions. Click `"Enabled`" and select the new hybrid worker.)"
}

# restart the app service
Write-Output "Restarting app service"
Restart-AzWebApp -ResourceGroupName $NmeRg -Name $NmeWebApp.Name

