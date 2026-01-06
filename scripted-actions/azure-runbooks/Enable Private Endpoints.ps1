#description: Restrict access to the sql database and keyvault used by Nerdio Manager. 
#tags: Nerdio, Preview
 
<# Notes:
 
This script will add private endpoints and service endpoints to allow the Nerdio Manager app service to communicate
with the sql database, keyvault, and automation account over a private network, with no traffic routed over the public 
internet. Access to the sql database and keyvault will be restricted to the private network. 

If other NME components, such as Intune Insights, Cost Calculator, or Real Time Insights have been enabled, they will
be added to the private network with private endpoints. The script can be re-run to add additional components to the
private networking.

The MakeAppServicePrivate parameter can be set to 'true' to further limit access to the app service to clients on the 
private network or peered networks. Supplying ResourceIds for one ore more existing networks will cause those networks 
to be peered to the new private network. 

If the VNet and Subnets already exist, the existing resources will be used and address ranges will not be changed. 
If they do not exist, they will be created. Names for resources created by this script, such as private endpoint names, 
can be customized by cloning this script and editing the variables at the top of the script.

If MakeSaStoragePrivate is True, the scripted actions storage account will be put on the private vnet. AVD VMs will need access to 
the storage account to run scripted actions. Use the PeerVnetIds parameter to peer the AVD vnet to the private 
endpoint vnet.
 
#>
 
<# Variables:
{
  "PrivateLinkVnetName": {
    "Description": "VNet for private endpoints. If the vnet does not exist, it will be created. If specifying an existing vnet, the vnet or its resource group must be linked to Nerdio Manager in Settings->Azure environment",
    "IsRequired": true,
    "DefaultValue": "nmw-private-vnet"
  },
  "VnetAddressRange": {
    "Description": "Address range for private endpoint vnet. Ignored if vnet already exists.",
    "IsRequired": false,
    "DefaultValue": "10.250.250.0/23"
  },
  "PrivateEndpointSubnetName": {
    "Description": "Name of private endpoint subnet. If the subnet does not exist, it will be created.",
    "IsRequired": true,
    "DefaultValue": "nmw-privateendpoints-subnet"
  },
  "PrivateEndpointSubnetRange": {
    "Description": "Address range for private endpoint subnet. Ignored if subnet already exists.",
    "IsRequired": false,
    "DefaultValue": "10.250.250.0/24"
  },
  "AppServiceSubnetName": {
    "Description": "App service subnet name. If the subnet does not exist, it will be created.",
    "IsRequired": true,
    "DefaultValue": "nmw-app-subnet"
  },
  "AppServiceSubnetRange": {
    "Description": "Address range for app service subnet. Ignored if subnet already exists.",
    "IsRequired": false,
    "DefaultValue": "10.250.251.0/28"
  },
  "ExistingDNSZonesRG": {
    "Description": "If you have private DNS zones already configured for use with the new private endpoints, specify their resource group here. This script will retrieve the existing DNS Zones and link them to the private network. Nerdio Manager needs to be linked to this RG in Settings->Azure Environment, or temporarily assigned the Private DNS Zone Contributor role for these zones. No changes will be made to the private DNS zones apart from linking them to the private VNet if necessary.",
    "IsRequired": false,
    "DefaultValue": ""
  },
  "ExistingDNSZonesSubId": {
    "Description": "If your existing private DNS zones are in a separate subscription from NME, specify the subscription id here. Nerdio needs to be linked to this subscription in Settings, but can be unlinked after running this script.",
    "IsRequired": false,
    "DefaultValue": ""
  },
  "CssaStorageAccount": {
    "Description": "Values: Public, Restricted, or Private. AVD hosts require access to the scripted actions storage account, which stores install files such as the FSLogix installer, and windows scripted actions. Setting this to Restricted will keep the public endpoint enabled but restricted to the VNets linked to Nerdio Manager, allowing access from AVD networks. Setting this to Private will create private endpoints to put the scripted actions storage account on the AVD VNets and configure Azure Private DNS routing.",
    "IsRequired": false,
    "DefaultValue": "Restricted"
  },
  "PeerVnetIds": {
    "Description": "Optional. Values are 'All' or comma-separated list of Azure resource IDs of VNets to peer to private endpoint VNet. If 'All' then all linked VNets will be peered. The VNETs or their resource groups must be linked to Nerdio Manager in Settings->Azure environment. All VNets must be in the same subscription as Nerdio Manager. External VNets must be peered manually.",
    "IsRequired": false,
    "DefaultValue": ""
  },
  "MakeAppServicePrivate": {
    "Description": "WARNING: If set to true, only hosts on the VNet created by this script, or on peered VNets, will be able to access the app service URL.",
    "IsRequired": false,
    "DefaultValue": "false"
  },
  "SkipDNS": {
    "Description": "Skip all DNS operations including checking for existing private DNS zones, creating new DNS zones, and linking DNS zones to VNets. Use this if you want to manage DNS separately.",
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
    write-output "Getting NME app resources"
    Write-Verbose "Getting Nerdio Manager key vault"
    $script:NmeKeyVault = Get-AzKeyVault -VaultName $keyvaultName
    $script:NmeRg = $NmeKeyVault.ResourceGroupName
    $NmeResourceTagName = "NMW_RESOURCE"
    $keyvaultTags = $NmeKeyVault.Tags
    $key = $keyvaultTags.GetEnumerator() | Where-Object { $_.Value -eq "PAAS" } | Select-Object -ExpandProperty Name
    if (!$Key) {
        # Get storage account where any tag value equals 'CUSTOM_SCRIPTS_STORAGE_ACCOUNT'
        $ScriptedActionStorageAccount = Get-AzStorageAccount -ResourceGroupName $NmeRg | Where-Object { $_.Tags.Values -contains "CUSTOM_SCRIPTS_STORAGE_ACCOUNT" }
        $key = $ScriptedActionStorageAccount.Tags.GetEnumerator() | Where-Object { $_.Value -eq "CUSTOM_SCRIPTS_STORAGE_ACCOUNT" } | Select-Object -ExpandProperty Key
    }
    else {
        $key = 'NMW_OBJECT_TYPE'
    }
    if ($ScriptedActionStorageAccount) {
        $script:NmeScriptedActionStorageAccountName = $ScriptedActionStorageAccount.StorageAccountName
    }
    else {
        write-warning "Unable to find Cssa storage account. It should have a tag with value CUSTOM_SCRIPTS_STORAGE_ACCOUNT"
    }
    Write-Verbose "Getting Nerdio Manager sql server"
    # First check to see if there's a sql server with tag "$Prefix`_RESOURCE" and value "PRIMARY_SQL_SERVER"
    $SqlServer = Get-AzSqlServer -ResourceGroupName $nmerg | Where-Object {$_.tags[$NmeResourceTagName] -eq 'PRIMARY_SQL_SERVER'}

    # if we didn't find a sql server, fall back to previous method of finding the sql server
    if (!$SqlServer) {
        if ($key){
            $SqlServer = Get-AzSqlServer -ResourceGroupName $nmerg | ? ServerName -NotMatch '-secondary' | Where-Object {$_.tags[$key] -ne 'INTUNE_INSIGHTS_DEPLOYMENT_RESOURCE' -and $_.tags[$key] -ne 'EIDO_DEPLOYMENT_RESOURCE' -and $_.tags[$key] -ne 'REAL_TIME_INSIGHTS_DEPLOYMENT_RESOURCE' -and $_.tags[$key] -ne'NERDIO_COPILOT_DEPLOYMENT_RESOURCE'}
        }
        else {
            $SqlServer = Get-AzSqlServer -ResourceGroupName $nmerg | ? ServerName -NotMatch '-secondary'
        }
        if ($SqlServer.count -ne 1) {
            Throw "Unable to find NME sql server. Please add the tag '$NmeResourceTagName' with value 'PRIMARY_SQL_SERVER' to the primary sql server used by Nerdio Manager and rerun this script."
        }
        else {
            $script:NmeSqlServerName = $SqlServer.ServerName
            $script:NmeSqlServerFQDN = $SqlServer.FullyQualifiedDomainName
        }
    }
    # Get database with tag displayName = Database
    $NmeDatabase = Get-AzSqlDatabase -ResourceGroupName $nmeRg -ServerName $nmeSqlServerName | Where-Object DatabaseName -ne 'master' | Where-Object {$_.tags['displayName'] -eq 'Database'}
    if ($NmeDatabase.count -ne 1) {
        write-error "Unable to find NME database."
    }
    else {
        $script:NmeDatabaseName = $NmeDatabase.DatabaseName
    }
    # look for secondary sql server with tag "$NmeResourceTagName" and value "SECONDARY_SQL_SERVER"
    $SqlSecondary = Get-AzSqlServer -ResourceGroupName $nmerg | Where-Object {$_.tags[$NmeResourceTagName] -eq 'SECONDARY_SQL_SERVER'}
    if (!($SqlSecondary)){ $SqlSecondary = Get-AzSqlServer -ResourceGroupName $nmerg | ? ServerName -Match '-secondary' }
    if ($SqlSecondary) {
        $script:NmeSqlSecondaryServerName = $SqlSecondary.ServerName
    }
    $script:NmeSqlDbName = (Get-AzSqlDatabase -ResourceGroupName $nmeRg -ServerName $nmeSqlServerName | Where-Object DatabaseName -ne 'master').DatabaseName

    if ($key) {
        $cclwebapp = Get-AzWebApp -ResourceGroupName $NmeRg | Where-Object { $_.Tags.Keys -contains $key } | Where-Object {$_.tags[$key] -eq 'CC_DEPLOYMENT_RESOURCE'}
        if ($cclwebapp) {
            Write-Verbose "Found CCL web app"
            $script:NmeCclWebAppName = $cclwebapp.Name
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
            $script:NmeCclStorageAccountName = $script:NmeCclStorageAccountName = Get-AzStorageAccount -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue | Where-Object { $_.Tags.Keys -contains $key } | Where-Object {$_.tags[$key] -eq 'CC_DEPLOYMENT_RESOURCE'} | Select-Object -ExpandProperty StorageAccountName
        }
        # get intune insights web app. tag value is INTUNE_INSIGHTS_DEPLOYMENT_RESOURCE
        $iiwebapp = Get-AzWebApp -ResourceGroupName $NmeRg | Where-Object { $_.Tags.Keys -contains $key } | Where-Object {$_.tags[$key] -eq 'INTUNE_INSIGHTS_DEPLOYMENT_RESOURCE'}
        # make sure there's only one web app in $iiwebapp
        if ($iiwebapp.count -gt 1) {
            Throw "Found more than one Intune Insights web app. Please remove any Intune Insights web apps no longer in use."
        }
        if ($iiwebapp) {
            # get key vault and sql server with tag INTUNE_INSIGHTS_DEPLOYMENT_RESOURCE
            Write-Verbose "Found Intune Insights web app"
            $script:NmeIiWebAppName = $iiwebapp.Name
            Write-Verbose "Getting Intune Insights Key Vault"
            $script:NmeIiKeyVaultName = Get-AzKeyVault -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue | Where-Object { $_.Tags.Keys -contains $key } | Where-Object {$_.tags[$key] -eq 'INTUNE_INSIGHTS_DEPLOYMENT_RESOURCE'} | Select-Object -ExpandProperty VaultName
            Write-Verbose "Getting Intune Insights Sql Server"
            $script:NmeIiSqlServerName = Get-AzSqlServer -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue | Where-Object { $_.Tags.Keys -contains $key } | Where-Object {$_.tags[$key] -eq 'INTUNE_INSIGHTS_DEPLOYMENT_RESOURCE'} | Select-Object -ExpandProperty ServerName
        }

    }
   
    Write-Verbose "Getting DPS Storage Account"
    # try get dps storage account by tag using nmeresourcetagname
    $script:NmeDpsStorageAccountName = get-azstorageaccount -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue | Where-Object {$_.tags[$NmeResourceTagName] -eq 'DPS_STORAGE_ACCOUNT'} | Select-Object -ExpandProperty StorageAccountName
    if (!$script:NmeDpsStorageAccountName) {
        Write-Verbose "DPS storage account not found by tag, trying by name pattern"
        $script:NmeDpsStorageAccountName = Get-AzStorageAccount -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue | Where-Object { $_.StorageAccountName -match "^dps" } | Select-Object -ExpandProperty StorageAccountName
    }
    if ($script:NmeDpsStorageAccountName.count -ne 1) {
        Write-Warning "Unable to find DPS storage account. If you are using dps and would like the to put storage account on private endpoints, please add the tag '$NmeResourceTagName' with value 'DPS_STORAGE_ACCOUNT' to the DPS storage account used by Nerdio Manager and rerun this script."
    }
    
    Write-Verbose "Getting Nerdio Manager web app"
    # try get nme web app by tag using nmeresourcetagname
    $script:NmeWebApp = Get-AzWebApp -ResourceGroupName $NmeRg | Where-Object {$_.tags[$NmeResourceTagName] -eq 'NERDIO_MANAGER_WEBAPP'}
    if (!$NmeWebApp) {
        # get web app with tag 
        $script:NmeWebApp = Get-AzWebApp -ResourceGroupName $NmeRg | Where-Object { $_.Tags.Keys -contains $key } | Where-Object {$_.tags[$key] -eq 'PAAS'}
    }
    if (!$NmeWebApp) {
        Write-Verbose "NME web app not found by tag, trying by app settings"
            $webapps = Get-AzWebApp -ResourceGroupName $NmeRg 
        if ($webapps){
            $script:NmeWebApp = $webapps | Where-Object { ($_.siteconfig.appsettings | where-object name -eq "Deployment:KeyVaultName" | Select-Object -ExpandProperty value) -eq $keyvaultName }
        }
        else {
            throw "Unable to find Nerdio Manager web app. Please add the tag '$NmeResourceTagName' with value 'NERDIO_MANAGER_WEBAPP' to the Nerdio Manager web app and rerun this script."
        }
    }
    if ($NmeWebApp.count -ne 1) {
        throw "Unable to find Nerdio Manager web app. Please add the tag '$NmeResourceTagName' with value 'NERDIO_MANAGER_WEBAPP' to the Nerdio Manager web app and rerun this script."
    }

    write-verbose "Getting Nerdio Manager Application Insights"
    # try get nme app insights by tag using nmeresourcetagname
    try {
        $NmeAppInsights = Get-AzApplicationInsights -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue | Where-Object {$_.tag[$NmeResourceTagName] -eq 'NERDIO_MANAGER_APPINSIGHTS' }
    } catch{}
    if (!$NmeAppInsights) {
        Write-Verbose "NME App Insights not found by tag, trying by instrumentation key"
        $NmeAppInsights = Get-AzApplicationInsights -ResourceGroupName $NmeRg | Where-Object { $_.InstrumentationKey -eq ($NmeWebApp.siteconfig.appsettings | Where-Object  {$_.name -eq 'ApplicationInsights:InstrumentationKey'} | Select-Object -ExpandProperty value) }
    }
    if ($NmeAppInsights.count -ne 1) {
        throw "Unable to find NME App Insights. Please add the tag '$NmeResourceTagName' with value 'NERDIO_MANAGER_APPINSIGHTS' to the Nerdio Manager Application Insights resource and rerun this script."
    }
    #$script:NmeAppInsightsLAWName = ($NmeAppInsights.WorkspaceResourceId).Split("/")[-1]
    $script:NmeAppInsightsName = $NmeAppInsights.name
    $script:NmeAppServicePlanName = $NmeWebApp.ServerFarmId.Split("/")[-1]
    $script:NmeSubscriptionId = ($NmeWebApp.siteconfig.appsettings | Where-Object name -eq 'Deployment:SubscriptionId').value
    $script:NmeTagPrefix = ($NmeWebApp.siteconfig.appsettings | Where-Object name -eq 'Deployment:AzureTagPrefix').value
    $script:NmeLogAnalyticsWorkspaceId = ($NmeWebApp.siteconfig.appsettings | Where-Object name -eq 'Deployment:LogAnalyticsWorkspace').value
    $script:NmeAutomationAccountName = ($NmeWebApp.siteconfig.appsettings | Where-Object name -eq 'Deployment:AutomationAccountName').value
    $script:NmeScriptedActionsAccountName = (($NmeWebApp.siteconfig.appsettings | Where-Object name -eq 'Deployment:ScriptedActionAccount').value).Split("/")[-1]
    $script:NmeRegion = $NmeKeyVault.Location

    # Find Real Time Insights components if they exist
    # Find RTI sql server
    try {$RtiSqlServer = Get-AzSqlServer -ResourceGroupName $nmerg | Where-Object {$_.tags[$NmeResourceTagName] -eq 'REAL_TIME_INSIGHTS_SQL_SERVER'}} 
    catch{}
    # if not found, try previous method
    if (!$RtiSqlServer) {
        if ($key){
            $RtiSqlServer = Get-AzSqlServer -ResourceGroupName $nmerg | Where-Object { $_.Tags.Keys -contains $key } | Where-Object {$_.tags[$key] -eq 'REAL_TIME_INSIGHTS_DEPLOYMENT_RESOURCE'}
        }
    }
    if ($RtiSqlServer) {
        Write-Verbose "Found Real Time Insights sql server"
        $script:NmeRtiSqlServerName = $RtiSqlServer.ServerName
    }
    # find RTI web app
    try {
        $RtiWebApp = Get-AzWebApp -ResourceGroupName $NmeRg | Where-Object {$_.tags[$NmeResourceTagName] -eq 'REAL_TIME_INSIGHTS_WEBAPP'}
    } catch{}
    # if not found, try previous method
    if (!$RtiWebApp) {
        if ($key){
            $RtiWebApp = Get-AzWebApp -ResourceGroupName $NmeRg | Where-Object { $_.Tags.Keys -contains $key } | Where-Object {$_.tags[$key] -eq 'REAL_TIME_INSIGHTS_DEPLOYMENT_RESOURCE'}
        }
        else {
            $RtiWebApp = Get-AzWebApp -ResourceGroupName $NmeRg
        }
    }
    if ($RtiWebApp) {
        Write-Verbose "Found Real Time Insights web app"
        $script:NmeRtiWebAppName = $RtiWebApp.Name
    }
    # find RTI key vault
    try {
        $RtiKeyVault = Get-AzKeyVault -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue | Where-Object {$_.tags[$NmeResourceTagName] -eq 'REAL_TIME_INSIGHTS_KEYVAULT'}
    } catch{}
    # if not found, try previous method
    if (!$RtiKeyVault) {
        if ($key){
            $RtiKeyVault = Get-AzKeyVault -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue | Where-Object { $_.Tags.Keys -contains $key } | Where-Object {$_.tags[$key] -eq 'REAL_TIME_INSIGHTS_DEPLOYMENT_RESOURCE'}
        }
        else {
            $RtiKeyVault = Get-AzKeyVault -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue
        }
    }
    if ($RtiKeyVault) {
        Write-Verbose "Found Real Time Insights key vault"
        $script:NmeRtiKeyVaultName = $RtiKeyVault.VaultName
    }
    # find RTI storage account
    try {
        $RtiStorageAccount = Get-AzStorageAccount -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue | Where-Object {$_.tags[$NmeResourceTagName] -eq 'REAL_TIME_INSIGHTS_STORAGE_ACCOUNT'}
    } catch{}
    # if not found, try previous method
    if (!$RtiStorageAccount) {
        if ($key){
            $RtiStorageAccount = Get-AzStorageAccount -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue | Where-Object { $_.Tags.Keys -contains $key } | Where-Object {$_.tags[$key] -eq 'REAL_TIME_INSIGHTS_DEPLOYMENT_RESOURCE'}
        }
        else {
            $RtiStorageAccount = Get-AzStorageAccount -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue
        }
    }
    if ($RtiStorageAccount) {
        Write-Verbose "Found Real Time Insights storage account"
        $script:NmeRtiStorageAccountName = $RtiStorageAccount.StorageAccountName
    }
}

Set-NmeVars -keyvaultName $KeyVaultName
$Prefix = $NmeTagPrefix

# define variables for all azure resources this script will create

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
$IiKvPrivateEndpointName = "$Prefix-ii-kv-privateendpoint"
$IiAppServicePrivateEndpointName = "$Prefix-ii-appservice-privateendpoint"
$IiSqlPrivateEndpointName = "$Prefix-ii-sql-privateendpoint"
$RtiKvPrivateEndpointName = "$Prefix-rti-kv-privateendpoint"
$RtiSqlPrivateEndpointName = "$Prefix-rti-sql-privateendpoint"
$RtiAppServicePrivateEndpointName = "$Prefix-rti-appservice-privateendpoint"
$RtiStoragePrivateEndpointName = "$Prefix-rti-storage-privateendpoint"

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
$CclAppServiceDnsZoneGroupName = "$Prefix-ccl-appservice-dnszonegroup"
$DpsStoragePrivateDnsZoneGroupName = "$Prefix-dps-storage-dnszonegroup"
$IiKvDnsZoneGroupName = "$Prefix-ii-kv-dnszonegroup"
$IiSqlDnsZoneGroupName = "$Prefix-ii-sql-dnszonegroup"
$IiAppServiceDnsZoneGroupName = "$Prefix-ii-appservice-dnszonegroup"
$RtiKvDnsZoneGroupName = "$Prefix-rti-kv-dnszonegroup"
$RtiSqlDnsZoneGroupName = "$Prefix-rti-sql-dnszonegroup"
$RtiAppServiceDnsZoneGroupName = "$Prefix-rti-appservice-dnszonegroup"
$RtiStorageDnsZoneGroupName = "$Prefix-rti-storage-dnszonegroup"


# define variables for private link service connection names
$KvServiceConnectionName = "$Prefix-app-kv-serviceconnection"
$SqlServiceConnectionName = "$Prefix-app-sql-serviceconnection"
$AutomationServiceConnectionName = "$Prefix-app-automation-serviceconnection"
$ScriptedActionsServiceConnectionName = "$Prefix-app-scriptedactions-serviceconnection"
$CssaStorageServiceConnectionName = "$Prefix-app-sa-storage-serviceconnection"
$MonitorServiceConnectionName = "$Prefix-app-monitor-serviceconnection"
$AppServiceServiceConnectionName = "$Prefix-app-appservice-serviceconnection"
$CclKvServiceConnectionName = "$Prefix-ccl-kv-serviceconnection"
$CclAppServiceServiceConnectionName = "$Prefix-ccl-appservice-serviceconnection"
$CclStorageServiceConnectionName = "$Prefix-ccl-storage-serviceconnection"
$DpsStorageServiceConnectionName = "$Prefix-dps-storage-serviceconnection"
$IiKvServiceConnectionName = "$Prefix-ii-kv-serviceconnection"
$IiAppServiceServiceConnectionName = "$Prefix-ii-appservice-serviceconnection"
$IiSqlServiceConnectionName = "$Prefix-ii-sql-serviceconnection"
$RtiKvServiceConnectionName = "$Prefix-rti-kv-serviceconnection"
$RtiSqlServiceConnectionName = "$Prefix-rti-sql-serviceconnection"
$RtiAppServiceServiceConnectionName = "$Prefix-rti-appservice-serviceconnection"
$RtiStorageServiceConnectionName = "$Prefix-rti-storage-serviceconnection"

# web app subnet delegation
$WebAppSubnetDelegationName = "$Prefix-app-webapp-subnetdelegation"

# define Azure monitor private link service settings
$MakeAzureMonitorPrivate = $false
$IngestionAccessMode = 'Open'
$QueryAccessMode = 'Open'

# define variables for private DNS zone links
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
$FileStoragePrivateDnsZoneLinkName = "$Prefix-filestorage-privatelink"
$BlobStoragePrivateDnsZoneLinkName = "$Prefix-blobstorage-privatelink"

# Define variables for all DNS zone names
if ($NmeWebApp.DefaultHostName -match "azurewebsites.us") {
    $KeyVaultDnsZoneName = "privatelink.vaultcore.usgovcloudapi.net"
    $SqlDnsZoneName = "privatelink.database.usgovcloudapi.net"
    $AutomationDnsZoneName = "privatelink.azure-automation.us"
    $StorageDnsZoneName = "privatelink.blob.core.usgovcloudapi.net"
    $AppServiceDnsZoneName = "privatelink.azurewebsites.us"
    $MonitorDnsZoneName = "privatelink.monitor.azure.us"
    $OpsDnsZoneName = "privatelink.oms.opinsights.azure.us"
    $OdsDnsZoneName = "privatelink.ods.opinsights.azure.us"
    $MonitorAgentDnsZoneName = "privatelink.agentsvc.azure-automation.us"
    $AzureManagementApi = "management.usgovcloudapi.net"
} else {
    $KeyVaultDnsZoneName = "privatelink.vaultcore.azure.net"
    $SqlDnsZoneName = "privatelink.database.windows.net"
    $AutomationDnsZoneName = "privatelink.azure-automation.net"
    $StorageDnsZoneName = "privatelink.blob.core.windows.net"
    $AppServiceDnsZoneName = "privatelink.azurewebsites.net"
    $MonitorDnsZoneName = "privatelink.monitor.azure.com"
    $OpsDnsZoneName = "privatelink.oms.opinsights.azure.com"
    $OdsDnsZoneName = "privatelink.ods.opinsights.azure.com"
    $MonitorAgentDnsZoneName = "privatelink.agentsvc.azure-automation.net"
    $AzureManagementApi = 'management.azure.com'
}


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

        $jobs = Get-AzAutomationJob -resourcegroupname $NmeRg -AutomationAccountName $NmeScriptedActionsAccountName | ? status -match 'completed|Failed' | ? {$_.EndTime.datetime -gt (get-date).AddMinutes(-$MinutesAgo)}
        foreach ($job in $jobs){
            $details = Get-AzAutomationJob -id $job.JobId -resourcegroupname $NmeRg -AutomationAccountName $NmeScriptedActionsAccountName 
            Invoke-WebRequest -UseBasicParsing -Uri $details.JobParameters.scriptUri -OutFile .\JobScript.ps1 
            $JobHash = Get-FileHash .\JobScript.ps1 
            if ($JobHash.hash -eq $ThisScriptHash.hash){
                Write-Output "Output of previous script run:"
                $JobOutput = Get-AzAutomationJobOutput -Id $details.JobId -resourcegroupname $NmeRg -AutomationAccountName $NmeScriptedActionsAccountName
                $JobOutput | select summary -ExpandProperty summary
                
                Write-Output "App Service restarted after running this script."
                if (($minutesago - ((get-date).AddMinutes(-$MinutesAgo).ToUniversalTime() - $app.LastModifiedTimeUtc).minutes) -lt $MinutesAgo){
                    write-output "If you need to re-run the script, please wait $($minutesago - ((get-date).AddMinutes(-$MinutesAgo).ToUniversalTime() - $app.LastModifiedTimeUtc).minutes) minutes and try again."
                }
                $joboutput| Where-Object type -eq warning | select summary -ExpandProperty summary | write-warning
                Exit
            }
        }
    }
}
    
Check-LastRunResults

# Check if nme app service is already vnet integrated
if ($NmeWebApp.virtualNetworkSubnetId){
    Write-Output "NME App service VNet integration already enabled. Confirming subnet matches current parameters"
    if (($NmeWebApp.virtualNetworkSubnetId -notmatch $AppServiceSubnetName) -or ($NmeWebApp.virtualNetworkSubnetId -notmatch $PrivateLinkVnetName)) {
        Write-output "NME App service is already VNet integrated, but the subnet does not match the specified PrivateLinkVnetName or AppServiceSubnetName parameters provided."
        write-error "NME App service is already VNet integrated, but the subnet does not match the specified PrivateLinkVnetName or AppServiceSubnetName parameters provided." 
        throw "NME App service is already VNet integrated, but the subnet does not match the specified PrivateLinkVnetName or AppServiceSubnetName parameters provided."
    } 
}


if ($PeerVnetIds -eq 'All') {
    $VnetIds = Get-AzVirtualNetwork | ? {if ($_.tag){$True}}| Where-Object {$_.tag["$Prefix`_OBJECT_TYPE"] -eq 'LINKED_NETWORK'} -ErrorAction SilentlyContinue | Where-Object id -ne $vnet.id | Select-Object -ExpandProperty Id
}
else {
    $VnetIds = if ($PeerVnetIds) { $PeerVnetIds -split ',' } else { @() }
}
# set resource group for dns zones
if ($SkipDNS -eq 'True') {
    Write-Output "SkipDNS is enabled - skipping all DNS zone operations"
    # Set DNS variables to null when skipping DNS operations
    $DnsRg = $null
    $KeyVaultDnsZone = $null
    $SqlDnsZone = $null
    $AutomationDnsZone = $null
    $StorageDnsZone = $null
    $MonitorDnsZone = $null
    $OpsDnsZone = $null
    $OdsDnsZone = $null
    $MonitorAgentDnsZone = $null
    $AppServiceDnsZone = $null
    $ExistingDNSZonesRG = $null
}
elseif ($ExistingDNSZonesRG) {
    $DnsRg = $ExistingDNSZonesRG
    if ($existingDNSZonesSubId) {
        Write-Output "Setting context to subscription $existingDNSZonesSubId to retrieve existing DNS zones"
        $context = Set-AzContext -Subscription $existingDNSZonesSubId
    }
    try {
        # get DNS zones
        $RequiredDnsZones = @($KeyVaultDnsZoneName, $SqlDnsZoneName, $AutomationDnsZoneName, $StorageDnsZoneName, $AppServiceDnsZoneName)
        $KeyVaultDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name $KeyVaultDnsZoneName -ErrorAction Stop
        $SqlDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name $SqlDnsZoneName -ErrorAction Stop
        $AutomationDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name $AutomationDnsZoneName -ErrorAction Stop
        $StorageDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name $StorageDnsZoneName -ErrorAction Stop
        if ($MakeAzureMonitorPrivate -eq 'True') {
            $RequiredDnsZones += $MonitorDnsZoneName, $OpsDnsZoneName, $OdsDnsZoneName, $MonitorAgentDnsZoneName
            $MonitorDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name $MonitorDnsZoneName -ErrorAction Stop
            $OpsDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name $OpsDnsZoneName -ErrorAction Stop
            $OdsDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name $OdsDnsZoneName -ErrorAction Stop
            $MonitorAgentDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name $MonitorAgentDnsZoneName -ErrorAction Stop
        }
        $AppServiceDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name $AppServiceDnsZoneName -ErrorAction Stop
        Write-Output "Found existing DNS zones in resource group $DnsRg"
    }
    catch {
        Write-Output "Unable to find one or more of the DNS zones in resource group $DnsRg. Required DNS zones for your configuration are: $RequiredDnsZones"
        Write-Error "Unable to find one or more of the DNS zones in resource group $DnsRg. Required DNS zones for your configuration are: $RequiredDnsZones"
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
    $KeyVaultDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name $KeyVaultDnsZoneName -ErrorAction SilentlyContinue
    $SqlDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name $SqlDnsZoneName -ErrorAction SilentlyContinue
    $AutomationDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name $AutomationDnsZoneName -ErrorAction SilentlyContinue
    $StorageDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name $StorageDnsZoneName -ErrorAction SilentlyContinue
    $MonitorDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name $MonitorDnsZoneName -ErrorAction SilentlyContinue
    $OpsDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name $OpsDnsZoneName -ErrorAction SilentlyContinue
    $OdsDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name $OdsDnsZoneName -ErrorAction SilentlyContinue
    $MonitorAgentDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name $MonitorAgentDnsZoneName -ErrorAction SilentlyContinue
    $AppServiceDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name $AppServiceDnsZoneName -ErrorAction SilentlyContinue
}

#### helper functions ####
function GetEntAppName {
    # check if mggraph module installed
    if (!(Get-Module -ListAvailable -Name Microsoft.Graph.Applications)) {
        Write-Verbose "Installing Microsoft.Graph.Applications module to retrieve app name"
        Install-Module -Name Microsoft.Graph.Applications -repository PSGallery -Force
    }
    $ctx = get-azcontext
    $graph = Connect-MgGraph -tenantid $ctx.Tenant.Id -ClientId $ctx.account -CertificateThumbprint $ctx.account.CertificateThumbprint -nowelcome
    $App = Get-MgApplicationbyAppId -AppId $ctx.account.Id
    disconnect-mggraph | out-null
    return $App.DisplayName
}

function GetVnets {
    # check if sql server public access is disabled; enable if needed
    # check if sql server public access is disabled; enable if needed
    $SqlServer = Get-AzSqlServer -ResourceGroupName $NmeRg -ServerName $NmeSqlServerName
    if ($SqlServer.PublicNetworkAccess -eq 'Disabled') {
        $SqlServerPrivate = $true
        Write-Verbose "SQL server public access is disabled. Enabling temporarily to retrieve vnet list."
        Set-AzSqlServer -ServerName $NmeSqlServerName -ResourceGroupName $NmeRg -PublicNetworkAccess "Enabled" | Out-Null
        Start-Sleep -Seconds 10
    }

    $moduleName = "SqlServer"
    if (-not (Get-Module -ListAvailable -Name $moduleName)) {
        Install-Module -Name $moduleName -Force 
    }
    $ctx = Get-AzContext
    $ResourceUrl = ($ctx.environment.sqldatabasednssuffix).TrimStart(".")
    $token = (Get-AzAccessToken -ResourceUrl "https://$ResourceUrl").Token
    try {
        $VNets = Invoke-SqlCmd -ServerInstance $NmeSqlServerFQDN `
                -Database $NmeSqlDbName `
                -AccessToken $token `
                -Query "SELECT * FROM [dbo].[Networks]"

    $VNets
    } catch {
        Write-Error "Unable to retrieve vnet list from Nerdio Manager database. $_"
        Throw $_
    }
    finally {
        # restore sql server public access setting
        if ($SqlServerPrivate -eq $true) {
            Write-Verbose "Restoring SQL server public access setting to Disabled."
            Set-AzSqlServer -ServerName $NmeSqlServerName -ResourceGroupName $NmeRg -PublicNetworkAccess "Disabled" | Out-Null
        }
    }
}


#### main script ####

# check to see if NMW app already has vnet integration enabled

# Get all existing private endpoints
$ExistingPrivateEndpoints = Get-AzPrivateEndpoint -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue

# Check if vnet created
$VNet = Get-AzVirtualNetwork -Name $PrivateLinkVnetName -ErrorAction SilentlyContinue
if ($VNet) {
    if ($VNet.Count -gt 1) {
        Throw "Found more than one VNet with name $PrivateLinkVnetName. Please remove any VNets no longer in use or use a unique name."
    }
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
 
    If ($vnetUpdated){
        $VNet | Set-AzVirtualNetwork
    }
 
} else {
    Write-Output "Creating VNet and subnets"
    $PrivateEndpointSubnet = New-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -AddressPrefix $PrivateEndpointSubnetRange -PrivateEndpointNetworkPoliciesFlag Disabled 
    $AppServiceSubnet = New-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -AddressPrefix $AppServiceSubnetRange 
    $VNet = New-AzVirtualNetwork -Name $PrivateLinkVnetName -ResourceGroupName $NmeRg -Location $NmeRegion -AddressPrefix $VnetAddressRange -Subnet $PrivateEndpointSubnet,$AppServiceSubnet
}

# Get linked VNets
$LinkedVnets = GetVnets


#region create DNS zones and links
if ($SkipDNS -ne 'True') {
    # Create and link private dns zone for key vault
    if ($existingDNSZonesSubId) {
        Write-Output "Setting context to subscription $existingDNSZonesSubId to create network links in DNS zones"
        $context = Set-AzContext -Subscription $existingDNSZonesSubId
    }
    if ($KeyVaultDnsZone) { 
        Write-Output "Found Private DNS Zone for Key Vault"
        #check for linked zone
        $KeyVaultZoneLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $KeyVaultDnsZoneName -ErrorAction SilentlyContinue
        if ($KeyVaultZoneLink.VirtualNetworkId -contains $vnet.id) {
            Write-Output "Private DNS Zone for Key Vault already linked to vnet"
        }
        else {
            Write-Output "Linking Private DNS Zone for Key Vault to vnet"
            $KeyVaultZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $KeyVaultDnsZoneName -Name $KeyVaultZoneLinkName -VirtualNetworkId $vnet.Id
        }
    }
    else {
        Write-Output "Creating Private DNS Zones and VNet link for Key Vault"
        $KeyVaultDnsZone = New-AzPrivateDnsZone -ResourceGroupName $NmeRg -Name $KeyVaultDnsZoneName
        $KeyVaultZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NmeRg -ZoneName $KeyVaultDnsZoneName -Name $KeyVaultZoneLinkName -VirtualNetworkId $vnet.Id
    }

    # Create and link private dns zone for sql 
    if ($SqlDnsZone) {
        Write-Output "Found Private DNS Zone for SQL"
        # check for linked zone
        $SqlZoneLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $SqlDnsZoneName -ErrorAction SilentlyContinue
        if ($SqlZoneLink.VirtualNetworkId -contains $vnet.id) {
            Write-Output "Private DNS Zone for SQL already linked to VNet"
        }
        else {
            Write-Output "Linking Private DNS Zone for SQL to VNet"
            $SqlZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $SqlDnsZoneName -Name $SqlZoneLinkName -VirtualNetworkId $vnet.Id
        }
    }
    else {
        Write-Output "Creating Private DNS Zones and VNet link for SQL"
        $SqlDnsZone = New-AzPrivateDnsZone -ResourceGroupName $NmeRg -Name $SqlDnsZoneName
        $SqlZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NmeRg -ZoneName $SqlDnsZoneName -Name $SqlZoneLinkName -VirtualNetworkId $vnet.Id
    }

    if ($StorageDnsZone) {
        Write-Output "Found Private DNS Zone for Storage"
        # check for linked zone
        $StorageZoneLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $StorageDnsZoneName -ErrorAction SilentlyContinue
        if ($StorageZoneLink.VirtualNetworkId -contains $vnet.id) {
            Write-Output "Private DNS Zone for Storage already linked to VNet"
        }
        else {
            Write-Output "Linking Private DNS Zone for Storage to VNet"
            $StorageZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $StorageDnsZoneName -Name $BlobZoneLinkName -VirtualNetworkId $vnet.Id
        }
        # if cssastorageaccount is Private, check for links to linked networks
        if ($CssaStorageAccount -eq 'Private') {
            foreach ($linkedVnet in $LinkedVnets) {
                $LinkedVNetName = (($linkedVnet.NetworkId -split '/')[8])
                if ($StorageZoneLink.VirtualNetworkId -contains $linkedVnet.NetworkId) {
                    Write-Output "Private DNS Zone for Storage already linked to linked VNet $LinkedVNetName"
                }
                else {
                    Write-Output "Linking Private DNS Zone for Storage to linked VNet $LinkedVNetName"
                    try {
                        $StorageZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $StorageDnsZoneName -Name "$BlobZoneLinkName-$LinkedVNetName" -VirtualNetworkId $linkedVnet.NetworkId
                    }
                    catch {
                        Write-Error "Unable to link Private DNS Zone for Storage to linked VNet $LinkedVNetName. $_"
                    }
                }
            }
        }
    }
    else {
        Write-Output "Creating Private DNS Zones and VNet link for Storage"
        $StorageDnsZone = New-AzPrivateDnsZone -ResourceGroupName $NmeRg -Name $StorageDnsZoneName
        $StorageZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NmeRg -ZoneName $StorageDnsZoneName -Name $BlobZoneLinkName -VirtualNetworkId $vnet.Id
        # create links to linked networks
        if ($CssaStorageAccount -eq 'Private') {
            foreach ($linkedVnet in $LinkedVnets) {
                Write-Output "Linking Private DNS Zone for Storage to linked VNet $($linkedVnet.Name)"
                try {$StorageZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NmeRg -ZoneName $StorageDnsZoneName -Name "$($BlobZoneLinkName)-$($linkedVnet.Name)" -VirtualNetworkId $linkedVnet.Id}
                catch {
                    Write-Error "Unable to link Private DNS Zone for Storage to linked VNet $($linkedVnet.Name). $_"
                }
            }
        }
    }

    # Create and link private dns zone for automation account
    if ($AutomationDnsZone) {
        Write-Output "Found Private DNS Zone for Automation"
        # check for linked zone
        $AutomationZoneLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $AutomationDnsZoneName -ErrorAction SilentlyContinue
        if ($AutomationZoneLink.VirtualNetworkId -contains $vnet.id) {
            Write-Output "Private DNS Zone for Automation already linked to vnet"
        }
        else {
            Write-Output "Linking Private DNS Zone for Automation to VNet"
            $AutomationZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $AutomationDnsZoneName -Name $AutomationZoneLinkName -VirtualNetworkId $vnet.Id
        }
    }
    else {
        Write-Output "Creating Private DNS Zones and VNet link for Automation"
        $AutomationDnsZone = New-AzPrivateDnsZone -ResourceGroupName $NmeRg -Name $AutomationDnsZoneName
        $AutomationZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NmeRg -ZoneName $AutomationDnsZoneName -Name $AutomationZoneLinkName -VirtualNetworkId $vnet.Id
    }

    # Create and link private dns zone for app service
    if ($AppServiceDnsZone) {
        Write-Output "Found Private DNS Zone for App Service"
        # check for linked zone
        $AppServiceZoneLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $AppServiceDnsZoneName -ErrorAction SilentlyContinue
        if ($AppServiceZoneLink.VirtualNetworkId -contains $vnet.id) {
            Write-Output "Private DNS Zone for App Service already linked to vnet"
        }
        else {
            Write-Output "Linking Private DNS Zone for App Service to vnet"
            $AppServiceZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $AppServiceDnsZoneName -Name $AppServiceZoneLinkName -VirtualNetworkId $vnet.Id
        }
    }
    else {
        Write-Output "Creating Private DNS Zones for App Service"
        $AppServiceDnsZone = New-AzPrivateDnsZone -ResourceGroupName $NmeRg -Name $AppServiceDnsZoneName
        $AppServiceZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NmeRg -ZoneName $AppServiceDnsZoneName -Name $AppServiceZoneLinkName -VirtualNetworkId $vnet.Id
    }

    if ($MakeAzureMonitorPrivate -eq 'True') {
        # Create and link private dns zone for monitor, ops, oms, and monitor agent
        if ($MonitorDnsZone) {
            Write-Output "Found Private DNS Zone for Monitor"
            # check for linked zone
            $MonitorZoneLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $MonitorDnsZoneName -ErrorAction SilentlyContinue
            if ($MonitorZoneLink.VirtualNetworkId -contains $vnet.id) {
                Write-Output "Private DNS Zone for Monitor already linked to vnet"
            }
            else {
                Write-Output "Linking Private DNS Zone for Monitor to vnet"
                $MonitorZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $MonitorDnsZoneName -Name $MonitorZoneLinkName -VirtualNetworkId $vnet.Id
            }
        }
        else {
            Write-Output "Creating Private DNS Zones for Monitor"
            $MonitorDnsZone = New-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name $MonitorDnsZoneName
            $MonitorZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $MonitorDnsZoneName -Name $MonitorZoneLinkName -VirtualNetworkId $vnet.Id
        }
        if ($OpsDnsZone) {
            Write-Output "Found Private DNS Zone for Ops"
            # check for linked zone
            $OpsZoneLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $OpsDnsZoneName -ErrorAction SilentlyContinue
            if ($OpsZoneLink.VirtualNetworkId -contains $vnet.id) {
                Write-Output "Private DNS Zone for Ops already linked to vnet"
            }
            else {
                Write-Output "Linking Private DNS Zone for Ops to vnet"
                $OpsZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $OpsDnsZoneName -Name $OpsZoneLinkName -VirtualNetworkId $vnet.Id
            }
        }
        else {
            Write-Output "Creating Private DNS Zones for Ops"
            $OpsDnsZone = New-AzPrivateDnsZone -ResourceGroupName $NmeRg -Name $OpsDnsZoneName
            $OpsZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NmeRg -ZoneName $OpsDnsZoneName -Name $OpsZoneLinkName -VirtualNetworkId $vnet.Id
        }
        if ($OdsDnsZone) {
            Write-Output "Found Private DNS Zone for ODS"
            # check for linked zone
            $OdsZoneLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $OdsDnsZoneName -ErrorAction SilentlyContinue
            if ($OdsZoneLink.VirtualNetworkId -contains $vnet.id) {
                Write-Output "Private DNS Zone for ODS already linked to vnet"
            }
            else {
                Write-Output "Linking Private DNS Zone for ODS to vnet"
                $OdsZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $OdsDnsZoneName -Name $OdsZoneLinkName -VirtualNetworkId $vnet.Id
            }
        }
        else {
            Write-Output "Creating Private DNS Zones for ODS"
            $OdsDnsZone = New-AzPrivateDnsZone -ResourceGroupName $NmeRg -Name $OdsDnsZoneName
            $OdsZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NmeRg -ZoneName $OdsDnsZoneName -Name $OdsZoneLinkName -VirtualNetworkId $vnet.Id
        }
        if ($MonitorAgentDnsZone) {
            Write-Output "Found Private DNS Zone for Monitor Agent"
            # check for linked zone
            $MonitorAgentZoneLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $MonitorAgentDnsZoneName -ErrorAction SilentlyContinue
            if ($MonitorAgentZoneLink.VirtualNetworkId -contains $vnet.id) {
                Write-Output "Private DNS Zone for Monitor Agent already linked to vnet"
            }
            else {
                Write-Output "Linking Private DNS Zone for Monitor Agent to vnet"
                $MonitorAgentZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $MonitorAgentDnsZoneName -Name $MonitorAgentZoneLinkName -VirtualNetworkId $vnet.Id
            }
        }
        else {
            Write-Output "Creating Private DNS Zones for Monitor Agent"
            $MonitorAgentDnsZone = New-AzPrivateDnsZone -ResourceGroupName $NmeRg -Name $MonitorAgentDnsZoneName
            $MonitorAgentZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NmeRg -ZoneName $MonitorAgentDnsZoneName -Name $MonitorAgentZoneLinkName -VirtualNetworkId $vnet.Id
        }
    }

    if ($PeerVnetIds) {
        $BlobStoragePrivateDnsZoneLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $StorageDnsZoneName -ErrorAction SilentlyContinue
        $MissingLinks = $VnetIds | Where-Object { $BlobStoragePrivateDnsZoneLink.VirtualNetworkId -notcontains $_ }
        if ($MissingLinks) {
            Write-Output "Linking Private DNS Zone for Blob Storage to peer vnets"
            $i = 0
            foreach ($vnetId in $MissingLinks) {
                $BlobStoragePrivateDnsZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $StorageDnsZoneName -Name ($BlobStoragePrivateDnsZoneLinkName + $i) -VirtualNetworkId $vnetId
                $i ++   
            }
        }
        if ($MakeAppServicePrivate -eq 'true'){
            $AppServicePrviateDnsZoneLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $AppServiceDnsZoneName -ErrorAction SilentlyContinue
            $AppServiceMissingLinks = $VnetIds | Where-Object { $AppServicePrviateDnsZoneLink.VirtualNetworkId -notcontains $_ }
            if ($AppServiceMissingLinks) {
                Write-Output "Linking Private DNS Zone for App Service to peer vnets"
                $i = 0
                foreach ($vnetId in $AppServiceMissingLinks) {
                    $AppServicePrviateDnsZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $AppServiceDnsZoneName -Name ($AppServiceZoneLinkName + $i) -VirtualNetworkId $vnetId
                    $i ++   
                }
            }
        }
    }

    if ($existingDNSZonesSubId) {
        Write-Output "Setting context to subscription $NmeSubscriptionId"
        $context = Set-AzContext -Subscription $NmeSubscriptionId
    }
}
#endregion



#region create private endpoints
$VNet = Get-AzVirtualNetwork -Name $PrivateLinkVnetName -ErrorAction SilentlyContinue
$PrivateEndpointSubnet = Get-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -VirtualNetwork $VNet
$AppServiceSubnet = Get-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -VirtualNetwork $VNet 
 
# check if keyvault private endpoint created
$KeyVault = Get-AzKeyVault -VaultName $KeyVaultName -ErrorAction SilentlyContinue
if ($ExistingPrivateEndpoints.PrivateLinkServiceConnections.PrivateLinkServiceId -contains $KeyVault.ResourceId) {
    Write-Output "Found Key Vault private endpoint"
    $KvPrivateEndpoint = $ExistingPrivateEndpoints | Where-Object { $_.PrivateLinkServiceConnections.PrivateLinkServiceId -eq $KeyVault.ResourceId }
} 
else {
    Write-Output "Configuring keyvault service connection and private endpoint"
    $KvServiceConnection = New-AzPrivateLinkServiceConnection -Name $KvServiceConnectionName -PrivateLinkServiceId $KeyVault.ResourceId -GroupId vault 
    $KvPrivateEndpoint = New-AzPrivateEndpoint -Name "$KvPrivateEndpointName" -ResourceGroupName $NmeRg -Location $NmeRegion -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $KvServiceConnection
}


# check if keyvault dns zone group created
if ($SkipDNS -ne 'True') {
    $KvDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $KvPrivateEndpoint.Name -ErrorAction SilentlyContinue
    if ($KvDnsZoneGroup) {
        Write-Output "Found Key Vault DNS zone group"
    } else {
        Write-Output "Configuring keyvault DNS zone group"
        $Config = New-AzPrivateDnsZoneConfig -Name $KeyVaultDnsZoneName  -PrivateDnsZoneId $KeyVaultDnsZone.ResourceId
        $KvDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$KvPrivateEndpointName" -Name "$KvDnsZoneGroupName" -PrivateDnsZoneConfig $config
    }
} else {
    Write-Output "Skipping Key Vault DNS zone group configuration (SkipDNS enabled)"
}

# check if ccl key vault exists
if ($NmeCclKeyVaultName) {
    # get ccl key vault
    $NmeCclKeyVault = Get-AzKeyVault -VaultName $NmeCclKeyVaultName
    # check if ccl key vault private endpoint exists in $ExistingPrivateEndpoints
    if ($ExistingPrivateEndpoints.PrivateLinkServiceConnections.PrivateLinkServiceId -contains $NmeCclKeyVault.ResourceId) {
        Write-Output "Found CCL Key Vault private endpoint"
        $CclKvPrivateEndpoint = $ExistingPrivateEndpoints | Where-Object { $_.PrivateLinkServiceConnections.PrivateLinkServiceId -eq $NmeCclKeyVault.ResourceId }
    }
    else {
        Write-Output "Configuring CCL keyvault service connection and private endpoint"
        $CclKvServiceConnection = New-AzPrivateLinkServiceConnection -Name $CclKvServiceConnectionName -PrivateLinkServiceId $NmeCclKeyVault.ResourceId -GroupId vault
        $CclKvPrivateEndpoint = New-AzPrivateEndpoint -Name "$CclKvPrivateEndpointName" -ResourceGroupName $NmeRg -Location $NmeRegion -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $CclKvServiceConnection
    }
    # check if ccl keyvault dns zone group created
    if ($SkipDNS -ne 'True') {
        $CclKvDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $CclKvPrivateEndpoint.Name -ErrorAction SilentlyContinue
        if ($CclKvDnsZoneGroup) {
            Write-Output "Found CCL Key Vault DNS zone group"
        } else {
            Write-Output "Configuring CCL keyvault DNS zone group"
            $Config = New-AzPrivateDnsZoneConfig -Name $KeyVaultDnsZoneName  -PrivateDnsZoneId $KeyVaultDnsZone.ResourceId
            $CclKvDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$CclKvPrivateEndpointName" -Name "$CclKvDnsZoneGroupName" -PrivateDnsZoneConfig $config
        }
    } else {
        Write-Output "Skipping CCL Key Vault DNS zone group configuration (SkipDNS enabled)"
    }
}

# check if intune insights key vault exists
if ($NmeIiKeyVaultName) {
    # get intune insights key vault
    $NmeIiKeyVault = Get-AzKeyVault -VaultName $NmeIiKeyVaultName
    # create if intune insights key vault private endpoint created
    $IiKvPrivateEndpoint = $ExistingPrivateEndpoints | Where-Object { $_.PrivateLinkServiceConnections.PrivateLinkServiceId -eq $NmeIiKeyVault.ResourceId }
    if ($IiKvPrivateEndpoint) {
        Write-Output "Found Intune Insights Key Vault private endpoint"
    } 
    else {
        Write-Output "Configuring Intune Insights keyvault service connection and private endpoint"
        $IiKvServiceConnection = New-AzPrivateLinkServiceConnection -Name $IiKvServiceConnectionName -PrivateLinkServiceId $NmeIiKeyVault.ResourceId -GroupId vault 
        $IiKvPrivateEndpoint = New-AzPrivateEndpoint -Name "$IiKvPrivateEndpointName" -ResourceGroupName $NmeRg -Location $NmeRegion -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $IiKvServiceConnection
    }
    # check if intune insights keyvault dns zone group created
    if ($SkipDNS -ne 'True') {
        $IiKvDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $IiKvPrivateEndpoint.Name -ErrorAction SilentlyContinue
        if ($IiKvDnsZoneGroup) {
            Write-Output "Found Intune Insights Key Vault DNS zone group"
        } else {
            Write-Output "Configuring Intune Insights keyvault DNS zone group"
            $Config = New-AzPrivateDnsZoneConfig -Name $KeyVaultDnsZoneName  -PrivateDnsZoneId $KeyVaultDnsZone.ResourceId
            $IiKvDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$IiKvPrivateEndpointName" -Name "$IiKvDnsZoneGroupName" -PrivateDnsZoneConfig $Config
        }
    } else {
        Write-Output "Skipping Intune Insights Key Vault DNS zone group configuration (SkipDNS enabled)"
    }
}

$SqlServer = Get-AzSqlServer -ResourceGroupName $NmeRg -ServerName $NmeSqlServerName

#check if sql private endpoint created
$SqlPrivateEndpoint = $ExistingPrivateEndpoints | Where-Object { $_.PrivateLinkServiceConnections.PrivateLinkServiceId -eq $SqlServer.ResourceId }
if ($SqlPrivateEndpoint) {
    Write-Output "Found SQL private endpoint"
} 
else {
    Write-Output "Configuring sql service connection and private endpoint"
    $SqlServiceConnection = New-AzPrivateLinkServiceConnection -Name $SqlServiceConnectionName -PrivateLinkServiceId $SqlServer.ResourceId -GroupId sqlserver 
    $SqlPrivateEndpoint = New-AzPrivateEndpoint -Name "$SqlPrivateEndpointName" -ResourceGroupName $NmeRg -Location $NmeRegion -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $SqlServiceConnection 
}

# check if sql dns zone group created
if ($SkipDNS -ne 'True') {
    $SqlDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $SqlPrivateEndpoint.Name -ErrorAction SilentlyContinue
    if ($SqlDnsZoneGroup) {
        Write-Output "Found SQL DNS zone group"
    } else {
        Write-Output "Configuring sql DNS zone group"
        $Config = New-AzPrivateDnsZoneConfig -Name $SqlDnsZoneName -PrivateDnsZoneId $SqlDnsZone.ResourceId
        $SqlDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$SqlPrivateEndpointName" -Name "$SqlDnsZoneGroupName" -PrivateDnsZoneConfig $config
    }
} else {
    Write-Output "Skipping SQL DNS zone group configuration (SkipDNS enabled)"
}

# if $nmeIisqlServerName is set, create private endpoint for intune insights sql server
if ($NmeIiSqlServerName) {
    $IiSqlServer = Get-AzSqlServer -ResourceGroupName $NmeRg -ServerName $NmeIiSqlServerName
    # check if intune insights sql private endpoint created
    $IiSqlPrivateEndpoint = $ExistingPrivateEndpoints | Where-Object { $_.PrivateLinkServiceConnections.PrivateLinkServiceId -eq $IiSqlServer.ResourceId }
    if ($IiSqlPrivateEndpoint) {
        Write-Output "Found Intune Insights SQL private endpoint"
    } 
    else {
        Write-Output "Configuring Intune Insights sql service connection and private endpoint"
        $IiSqlServiceConnection = New-AzPrivateLinkServiceConnection -Name $IiSqlServiceConnectionName -PrivateLinkServiceId $IiSqlServer.ResourceId -GroupId sqlserver 
        $IiSqlPrivateEndpoint = New-AzPrivateEndpoint -Name "$IiSqlPrivateEndpointName" -ResourceGroupName $NmeRg -Location $NmeRegion -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $IiSqlServiceConnection 
    }
    # check if intune insights sql dns zone group created
    if ($SkipDNS -ne 'True') {
        $IiSqlDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $IiSqlPrivateEndpoint.Name -ErrorAction SilentlyContinue
        if ($IiSqlDnsZoneGroup) {
            Write-Output "Found Intune Insights SQL DNS zone group"
        } else {
            Write-Output "Configuring Intune Insights sql DNS zone group"
            $Config = New-AzPrivateDnsZoneConfig -Name $SqlDnsZoneName -PrivateDnsZoneId $SqlDnsZone.ResourceId
            $IiSqlDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$IiSqlPrivateEndpointName" -Name "$IiSqlDnsZoneGroupName" -PrivateDnsZoneConfig $config
        }
    } else {
        Write-Output "Skipping Intune Insights SQL DNS zone group configuration (SkipDNS enabled)"
    }
}


# check if automation account private endpoint is created
$NmeAutomationAccountResourceId = "/subscriptions/$NmeSubscriptionId/resourceGroups/$NmeRg/providers/Microsoft.Automation/automationAccounts/$NmeAutomationAccountName"
$AutomationPrivateEndpoint = $ExistingPrivateEndpoints | Where-Object { $_.PrivateLinkServiceConnections.PrivateLinkServiceId -eq $NmeAutomationAccountResourceId }
if ($AutomationPrivateEndpoint) {
    Write-Output "Found Automation private endpoint"
} 
else {
    Write-Output "Configuring automation service connection and private endpoint"
    $AutomationServiceConnection = New-AzPrivateLinkServiceConnection -Name $AutomationServiceConnectionName -PrivateLinkServiceId $NmeAutomationAccountResourceId -GroupId DSCAndHybridWorker 
    $AutomationPrivateEndpoint = New-AzPrivateEndpoint -Name "$AutomationPrivateEndpointName" -ResourceGroupName $NmeRg -Location $NmeRegion -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $AutomationServiceConnection 

}
# check if automation account dns zone group created
if ($SkipDNS -ne 'True') {
    $AutomationDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $AutomationPrivateEndpoint.Name -ErrorAction SilentlyContinue
    if ($AutomationDnsZoneGroup) {
        Write-Output "Found Automation DNS zone group"
    } else {
        Write-Output "Configuring automation DNS zone group"
        $Config = New-AzPrivateDnsZoneConfig -Name $AutomationDnsZoneName -PrivateDnsZoneId $AutomationDnsZone.ResourceId
        $AutomationDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$AutomationPrivateEndpointName" -Name "$AutomationDnsZoneGroupName" -PrivateDnsZoneConfig $config
    }
} else {
    Write-Output "Skipping Automation DNS zone group configuration (SkipDNS enabled)"
}


# Get scripted action automation account
       
if ($NmeScriptedActionsAccountName) {
    $ScriptedActionsAccountResourceId = "/subscriptions/$NmeSubscriptionId/resourceGroups/$NmeRg/providers/Microsoft.Automation/automationAccounts/$NmeScriptedActionsAccountName"
    # check if scripted action automation account private endpoint is created
    $ScriptedActionsPrivateEndpoint = $ExistingPrivateEndpoints | Where-Object { $_.PrivateLinkServiceConnections.PrivateLinkServiceId -eq $ScriptedActionsAccountResourceId }
    if ($ScriptedActionsPrivateEndpoint) {
        Write-Output "Found scripted actions private endpoint"
    } 
    else {
        Write-Output "Configuring scripted actions service connection and private endpoint"
        $ScriptedActionsServiceConnection = New-AzPrivateLinkServiceConnection -Name $ScriptedActionsServiceConnectionName -PrivateLinkServiceId $ScriptedActionsAccountResourceId -GroupId DSCAndHybridWorker 
        $ScriptedActionsPrivateEndpoint = New-AzPrivateEndpoint -Name $ScriptedActionsPrivateEndpointName -ResourceGroupName $NmeRg -Location $NmeRegion -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $ScriptedActionsServiceConnection 
    }
    # check if scripted action automation account dns zone group created
    if ($SkipDNS -ne 'True') {
        $ScriptedActionsDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $ScriptedActionsPrivateEndpoint.Name -ErrorAction SilentlyContinue
        if ($ScriptedActionsDnsZoneGroup) {
            Write-Output "Found scripted actions DNS zone group"
        } else {
            Write-Output "Configuring scripted actions DNS zone group"
            $Config = New-AzPrivateDnsZoneConfig -Name $AutomationDnsZoneName -PrivateDnsZoneId $AutomationDnsZone.ResourceId
            $ScriptedActionsDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $ScriptedActionsPrivateEndpointName -Name "$ScriptedActionsDnsZoneGroupName" -PrivateDnsZoneConfig $config
        }
    } else {
        Write-Output "Skipping scripted actions DNS zone group configuration (SkipDNS enabled)"
    }


    $ScriptedActionStorageAccount = Get-AzStorageAccount -ResourceGroupName $NmeRg -Name $NmeScriptedActionStorageAccountName -ErrorAction SilentlyContinue
    # throw error if no scripted actions storage account found
    if (-not $ScriptedActionStorageAccount) {
        throw "No scripted actions storage account found in resource group $NmeRg"
    }
    # check if scripted action storage account private endpoint is created
    $ScriptedActionsStoragePrivateEndpoint = $ExistingPrivateEndpoints | Where-Object { $_.PrivateLinkServiceConnections.PrivateLinkServiceId -eq $ScriptedActionStorageAccount.Id }
    if ($ScriptedActionsStoragePrivateEndpoint) {
        Write-Output "Found scripted actions storage private endpoint"
    } 
    else {
        Write-Output "Configuring scripted actions storage service connection and private endpoint"
        $ScriptedActionsStorageServiceConnection = New-AzPrivateLinkServiceConnection -Name $CssaStorageServiceConnectionName -PrivateLinkServiceId $ScriptedActionStorageAccount.Id -GroupId blob 
        $ScriptedActionsStoragePrivateEndpoint = New-AzPrivateEndpoint -Name "$ScriptedActionsStoragePrivateEndpointName" -ResourceGroupName $NmeRg -Location $NmeRegion -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $ScriptedActionsStorageServiceConnection 
    }
    # check if scripted action storage account dns zone group created
    if ($SkipDNS -ne 'True') {
        $ScriptedActionsStorageDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $ScriptedActionsStoragePrivateEndpoint.Name -ErrorAction SilentlyContinue
        if ($ScriptedActionsStorageDnsZoneGroup) {
            Write-Output "Found scripted actions storage DNS zone group"
        } else {
            Write-Output "Configuring scripted actions storage DNS zone group"
            $Config = New-AzPrivateDnsZoneConfig -Name $StorageDnsZoneName -PrivateDnsZoneId $StorageDnsZone.ResourceId
            $ScriptedActionsStorageDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$ScriptedActionsStoragePrivateEndpointName" -Name $SaStoragePrivateDnsZoneGroupName -PrivateDnsZoneConfig $config
        }
    } else {
        Write-Output "Skipping scripted actions storage DNS zone group configuration (SkipDNS enabled)"
    }

    
}

if ($NmeCclStorageAccountName) {
    # Get ccl storage account
    $NmeCclStorageAccount = Get-AzStorageAccount -ResourceGroupName $NmeRg -Name $NmeCclStorageAccountName
    # check if ccl storage account private endpoint is created
    $CclStoragePrivateEndpoint = $ExistingPrivateEndpoints | Where-Object { $_.PrivateLinkServiceConnections.PrivateLinkServiceId -eq $NmeCclStorageAccount.Id }
    if ($CclStoragePrivateEndpoint) {
        Write-Output "Found CCL storage private endpoint"
    } 
    else {
        Write-Output "Configuring CCL storage service connection and private endpoint"
        $CclStorageServiceConnection = New-AzPrivateLinkServiceConnection -Name $CclStorageServiceConnectionName -PrivateLinkServiceId $NmeCclStorageAccount.Id -GroupId blob 
        $CclStoragePrivateEndpoint = New-AzPrivateEndpoint -Name "$CclStoragePrivateEndpointName" -ResourceGroupName $NmeRg -Location $NmeRegion -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $CclStorageServiceConnection 
    }
    # check if ccl storage account dns zone group created
    if ($SkipDNS -ne 'True') {
        $CclStorageDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $CclStoragePrivateEndpoint.Name -ErrorAction SilentlyContinue
        if ($CclStorageDnsZoneGroup) {
            Write-Output "Found CCL storage DNS zone group"
        } else {
            Write-Output "Configuring CCL storage DNS zone group"
            $Config = New-AzPrivateDnsZoneConfig -Name $StorageDnsZoneName -PrivateDnsZoneId $StorageDnsZone.ResourceId
            $CclStorageDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$CclStoragePrivateEndpointName" -Name $CclStoragePrivateDnsZoneGroupName -PrivateDnsZoneConfig $config
        }
    } else {
        Write-Output "Skipping CCL storage DNS zone group configuration (SkipDNS enabled)"
    }

}

if ($NmeDpsStorageAccountName) {
    # Get dps storage account
    $NmeDpsStorageAccount = Get-AzStorageAccount -ResourceGroupName $NmeRg -Name $NmeDpsStorageAccountName
    # check if dps storage account private endpoint is created
    $DpsStoragePrivateEndpoint = $ExistingPrivateEndpoints | Where-Object { $_.PrivateLinkServiceConnections.PrivateLinkServiceId -eq $NmeDpsStorageAccount.Id }
    if ($DpsStoragePrivateEndpoint) {
        Write-Output "Found DPS storage private endpoint"
    } 
    else {
        Write-Output "Configuring DPS storage service connection and private endpoint"
        $DpsStorageServiceConnection = New-AzPrivateLinkServiceConnection -Name $DpsStorageServiceConnectionName -PrivateLinkServiceId $NmeDpsStorageAccount.Id -GroupId blob 
        $DpsStoragePrivateEndpoint = New-AzPrivateEndpoint -Name "$DpsStoragePrivateEndpointName" -ResourceGroupName $NmeRg -Location $NmeRegion -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $DpsStorageServiceConnection 
    }
    # check if dps storage account dns zone group created
    if ($SkipDNS -ne 'True') {
        $DpsStorageDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $DpsStoragePrivateEndpoint.Name -ErrorAction SilentlyContinue
        if ($DpsStorageDnsZoneGroup) {
            Write-Output "Found DPS storage DNS zone group"
        } else {
            Write-Output "Configuring DPS storage DNS zone group"
            $Config = New-AzPrivateDnsZoneConfig -Name $StorageDnsZoneName -PrivateDnsZoneId $StorageDnsZone.ResourceId
            $DpsStorageDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$DpsStoragePrivateEndpointName" -Name $DpsStoragePrivateDnsZoneGroupName -PrivateDnsZoneConfig $config
        }
    } else {
        Write-Output "Skipping DPS storage DNS zone group configuration (SkipDNS enabled)"
    }
}
else {
    Write-Warning "Unable to find DPS storage account. Skipping private endpoint creation. You will need to manually create the private endpoint for the storage account."
}


$AppService = Get-AzWebApp -ResourceGroupName $NmeRg -Name $NmeWebApp.Name
# check if app service private endpoint is created
$AppServicePrivateEndpoint = $ExistingPrivateEndpoints | Where-Object { $_.PrivateLinkServiceConnections.PrivateLinkServiceId -eq $AppService.id }
if ($AppServicePrivateEndpoint) {
    Write-Output "Found App Service private endpoint"
} 
else {
    Write-Output "Configuring app service service connection and private endpoint"
    $AppServiceResourceId = $AppService.id
    $PrivateEndpointSubnet = Get-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -VirtualNetwork $VNet
    $AppServiceServiceConnection = New-AzPrivateLinkServiceConnection -Name $AppServiceServiceConnectionName -PrivateLinkServiceId $AppServiceResourceId -GroupId sites 
    $AppServicePrivateEndpoint = New-AzPrivateEndpoint -Name "$AppServicePrivateEndpointName" -ResourceGroupName $NmeRg -Location $NmeRegion -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $AppServiceServiceConnection 
}
# check if app service dns zone group created
if ($SkipDNS -ne 'True') {
    $AppServiceDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $AppServicePrivateEndpoint.Name -ErrorAction SilentlyContinue
    if ($AppServiceDnsZoneGroup) {
        Write-Output "Found App Service DNS zone group"
    } else {
        Write-Output "Configuring app service DNS zone group"
        $Config = New-AzPrivateDnsZoneConfig -Name $AppServiceDnsZoneName -PrivateDnsZoneId $AppServiceDnsZone.ResourceId
        $AppServiceDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$AppServicePrivateEndpointName" -Name $AppServicePrivateDnsZoneGroupName -PrivateDnsZoneConfig $config
    }
} else {
    Write-Output "Skipping App Service DNS zone group configuration (SkipDNS enabled)"
}


if ($NmeCclWebAppName) {
    $CclAppService = Get-AzWebApp -ResourceGroupName $NmeRg -Name $NmeCclWebAppName
    # check if ccl app service private endpoint is created
    $CclAppServicePrivateEndpoint = $ExistingPrivateEndpoints | Where-Object { $_.PrivateLinkServiceConnections.PrivateLinkServiceId -eq $CclAppService.id }
    if ($CclAppServicePrivateEndpoint) {
        Write-Output "Found CCL App Service private endpoint"
    } 
    else {
        Write-Output "Configuring CCL app service service connection and private endpoint"
        $CclAppServiceResourceId = $CclAppService.id
        $PrivateEndpointSubnet = Get-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -VirtualNetwork $VNet
        $CclAppServiceServiceConnection = New-AzPrivateLinkServiceConnection -Name $CclAppServiceServiceConnectionName -PrivateLinkServiceId $CclAppServiceResourceId -GroupId sites 
        $CclAppServicePrivateEndpoint = New-AzPrivateEndpoint -Name "$CclAppServicePrivateEndpointName" -ResourceGroupName $NmeRg -Location $NmeRegion -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $CclAppServiceServiceConnection 
    }
    # check if ccl app service dns zone group created
    if ($SkipDNS -ne 'True') {
        $CclAppServiceDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $CclAppServicePrivateEndpoint.Name -ErrorAction SilentlyContinue
        if ($CclAppServiceDnsZoneGroup) {
            Write-Output "Found CCL App Service DNS zone group"
        } else {
            Write-Output "Configuring CCL app service DNS zone group"
            $Config = New-AzPrivateDnsZoneConfig -Name $AppServiceDnsZoneName -PrivateDnsZoneId $AppServiceDnsZone.ResourceId
            $CclAppServiceDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$CclAppServicePrivateEndpointName" -Name $CclStoragePrivateDnsZoneGroupName -PrivateDnsZoneConfig $config
        }
    } else {
        Write-Output "Skipping CCL App Service DNS zone group configuration (SkipDNS enabled)"
    }
    $NmeCclWebApp = Get-AzWebApp -ResourceGroupName $NmeRg -Name $NmeCclWebAppName
    $cclwebapp = Get-AzResource -Id $NmeCclWebApp.id
    $cclwebapp.Properties.publicNetworkAccess = "Disabled"
    $cclwebapp | Set-AzResource -Force | Out-Null
}
# add section for NmeiiWebApp 
if ($NmeIiWebAppName) {
    $IiWebApp = Get-AzWebApp -ResourceGroupName $NmeRg -Name $NmeIiWebAppName
    # check if intune insights app service private endpoint is created
    $IiAppServicePrivateEndpoint = $ExistingPrivateEndpoints | Where-Object { $_.PrivateLinkServiceConnections.PrivateLinkServiceId -eq $IiWebApp.id }
    if ($IiAppServicePrivateEndpoint) {
        Write-Output "Found Intune Insights App Service private endpoint"
    } 
    else {
        Write-Output "Configuring Intune Insights app service service connection and private endpoint"
        $IiAppServiceResourceId = $IiWebApp.id
        $IiAppServiceServiceConnection = New-AzPrivateLinkServiceConnection -Name $IiAppServiceServiceConnectionName -PrivateLinkServiceId $IiAppServiceResourceId -GroupId sites 
        $IiAppServicePrivateEndpoint = New-AzPrivateEndpoint -Name "$IiAppServicePrivateEndpointName" -ResourceGroupName $NmeRg -Location $NmeRegion -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $IiAppServiceServiceConnection 
    }
    # check if intune insights app service dns zone group created
    if ($SkipDNS -ne 'True') {
        $IiAppServiceDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $IiAppServicePrivateEndpoint.Name -ErrorAction SilentlyContinue
        if ($IiAppServiceDnsZoneGroup) {
            Write-Output "Found Intune Insights App Service DNS zone group"
        } else {
            Write-Output "Configuring Intune Insights app service DNS zone group"
            $Config = New-AzPrivateDnsZoneConfig -Name $AppServiceDnsZoneName -PrivateDnsZoneId $AppServiceDnsZone.ResourceId
            $IiAppServiceDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$IiAppServicePrivateEndpointName" -Name $IiAppServiceDnsZoneGroupName -PrivateDnsZoneConfig $config
        }
    } else {
        Write-Output "Skipping Intune Insights App Service DNS zone group configuration (SkipDNS enabled)"
    }

}

# add private endpoints for real time insights app service
if ($NmeRtiWebAppName) {
    $RtiWebApp = Get-AzWebApp -ResourceGroupName $NmeRg -Name $NmeRtiWebAppName
    # check if rti app service private endpoint is created
    $RtiAppServicePrivateEndpoint = $ExistingPrivateEndpoints | Where-Object { $_.PrivateLinkServiceConnections.PrivateLinkServiceId -eq $RtiWebApp.id }
    if ($RtiAppServicePrivateEndpoint) {
        Write-Output "Found RTI App Service private endpoint"
    } 
    else {
        Write-Output "Configuring RTI app service service connection and private endpoint"
        $RtiAppServiceResourceId = $RtiWebApp.id
        $RtiAppServiceServiceConnection = New-AzPrivateLinkServiceConnection -Name $RtiAppServiceServiceConnectionName -PrivateLinkServiceId $RtiAppServiceResourceId -GroupId sites 
        $RtiAppServicePrivateEndpoint = New-AzPrivateEndpoint -Name "$RtiAppServicePrivateEndpointName" -ResourceGroupName $NmeRg -Location $NmeRegion -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $RtiAppServiceServiceConnection 
    }
    # check if rti app service dns zone group created
    if ($SkipDNS -ne 'True') {
        $RtiAppServiceDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $RtiAppServicePrivateEndpoint.Name -ErrorAction SilentlyContinue
        if ($RtiAppServiceDnsZoneGroup) {
            Write-Output "Found RTI App Service DNS zone group"
        } else {
            Write-Output "Configuring RTI app service DNS zone group"
            $Config = New-AzPrivateDnsZoneConfig -Name $AppServiceDnsZoneName -PrivateDnsZoneId $AppServiceDnsZone.ResourceId
            $RtiAppServiceDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$RtiAppServicePrivateEndpointName" -Name $RtiAppServiceDnsZoneGroupName -PrivateDnsZoneConfig $config
        }
    } else {
        Write-Output "Skipping RTI App Service DNS zone group configuration (SkipDNS enabled)"
    }
}
# add private endpoints for real time insights sql server
if ($NmeRtiSqlServerName) {
    $RtiSqlServer = Get-AzSqlServer -ResourceGroupName $NmeRg -ServerName $NmeRtiSqlServerName
    # check if rti sql private endpoint is created
    $RtiSqlPrivateEndpoint = $ExistingPrivateEndpoints | Where-Object { $_.PrivateLinkServiceConnections.PrivateLinkServiceId -eq $RtiSqlServer.ResourceId }
    if ($RtiSqlPrivateEndpoint) {
        Write-Output "Found RTI SQL private endpoint"
    } 
    else {
        Write-Output "Configuring RTI sql service connection and private endpoint"
        $RtiSqlServiceConnection = New-AzPrivateLinkServiceConnection -Name $RtiSqlServiceConnectionName -PrivateLinkServiceId $RtiSqlServer.ResourceId -GroupId sqlserver 
        $RtiSqlPrivateEndpoint = New-AzPrivateEndpoint -Name "$RtiSqlPrivateEndpointName" -ResourceGroupName $NmeRg -Location $NmeRegion -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $RtiSqlServiceConnection 
    }
    # check if rti sql dns zone group created
    if ($SkipDNS -ne 'True') {
        $RtiSqlDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $RtiSqlPrivateEndpoint.Name -ErrorAction SilentlyContinue
        if ($RtiSqlDnsZoneGroup) {
            Write-Output "Found RTI SQL DNS zone group"
        } else {
            Write-Output "Configuring RTI sql DNS zone group"
            $Config = New-AzPrivateDnsZoneConfig -Name $SqlDnsZoneName -PrivateDnsZoneId $SqlDnsZone.ResourceId
            $RtiSqlDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$RtiSqlPrivateEndpointName" -Name $RtiSqlDnsZoneGroupName -PrivateDnsZoneConfig $config
        }
    } else {
        Write-Output "Skipping RTI SQL DNS zone group configuration (SkipDNS enabled)"
    }
}
# add private endpoint for real time insights storage account
if ($NmeRtiStorageAccountName) {
    # Get rti storage account
    $NmeRtiStorageAccount = Get-AzStorageAccount -ResourceGroupName $NmeRg -Name $NmeRtiStorageAccountName
    # check if rti storage account private endpoint is created
    $RtiStoragePrivateEndpoint = $ExistingPrivateEndpoints | Where-Object { $_.PrivateLinkServiceConnections.PrivateLinkServiceId -eq $NmeRtiStorageAccount.Id }
    if ($RtiStoragePrivateEndpoint) {
        Write-Output "Found RTI storage private endpoint"
    } 
    else {
        Write-Output "Configuring RTI storage service connection and private endpoint"
        $RtiStorageServiceConnection = New-AzPrivateLinkServiceConnection -Name $RtiStorageServiceConnectionName -PrivateLinkServiceId $NmeRtiStorageAccount.Id -GroupId blob 
        $RtiStoragePrivateEndpoint = New-AzPrivateEndpoint -Name "$RtiStoragePrivateEndpointName" -ResourceGroupName $NmeRg -Location $NmeRegion -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $RtiStorageServiceConnection 
    }
    # check if rti storage account dns zone group created
    if ($SkipDNS -ne 'True') {
        $RtiStorageDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $RtiStoragePrivateEndpoint.Name -ErrorAction SilentlyContinue
        if ($RtiStorageDnsZoneGroup) {
            Write-Output "Found RTI storage DNS zone group"
        } else {
            Write-Output "Configuring RTI storage DNS zone group"
            $Config = New-AzPrivateDnsZoneConfig -Name $StorageDnsZoneName -PrivateDnsZoneId $StorageDnsZone.ResourceId
            $RtiStorageDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$RtiStoragePrivateEndpointName" -Name $RtiStorageDnsZoneGroupName -PrivateDnsZoneConfig $config
        }
    } else {
        Write-Output "Skipping RTI storage DNS zone group configuration (SkipDNS enabled)"
    }
}
# add private endpoint for real time insights key vault
if ($NmeRtiKeyVaultName) {
    # Get rti key vault
    $NmeRtiKeyVault = Get-AzKeyVault -ResourceGroupName $NmeRg -VaultName $NmeRtiKeyVaultName
    # check if rti key vault private endpoint is created
    $RtiKvPrivateEndpoint = $ExistingPrivateEndpoints | Where-Object { $_.PrivateLinkServiceConnections.PrivateLinkServiceId -eq $NmeRtiKeyVault.ResourceId }
    if ($RtiKvPrivateEndpoint) {
        Write-Output "Found RTI Key Vault private endpoint"
    } 
    else {
        Write-Output "Configuring RTI Key Vault service connection and private endpoint"
        $RtiKvServiceConnection = New-AzPrivateLinkServiceConnection -Name $RtiKvServiceConnectionName -PrivateLinkServiceId $NmeRtiKeyVault.ResourceId -GroupId vault 
        $RtiKvPrivateEndpoint = New-AzPrivateEndpoint -Name "$RtiKvPrivateEndpointName" -ResourceGroupName $NmeRg -Location $NmeRegion -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $RtiKvServiceConnection 
    }
    # check if rti key vault dns zone group created
    if ($SkipDNS -ne 'True') {
        $RtiKvDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $RtiKvPrivateEndpoint.Name -ErrorAction SilentlyContinue
        if ($RtiKvDnsZoneGroup) {
            Write-Output "Found RTI Key Vault DNS zone group"
        } else {
            Write-Output "Configuring RTI Key Vault DNS zone group"
            $Config = New-AzPrivateDnsZoneConfig -Name $KeyVaultDnsZoneName  -PrivateDnsZoneId $KeyVaultDnsZone.ResourceId
            $RtiKvDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$RtiKvPrivateEndpointName" -Name $RtiKvDnsZoneGroupName -PrivateDnsZoneConfig $Config
        }
    } else {
        Write-Output "Skipping RTI Key Vault DNS zone group configuration (SkipDNS enabled)"
    }
}
# if cssastorageaccount is private, create private endpoints for the cssa on all linked vnets and ensure prviate dns zone is linked to those vnets if SkipDNS is not True
if ($CssaStorageAccount -eq 'Private') {
     # Get cssa storage account
    
    $Sa = Get-AzStorageAccount -ResourceGroupName $NmeRg -Name $NmeScriptedActionStorageAccountName
    foreach ($VnetId in ($LinkedVnets.NetworkId | select -unique)) {
        $LinkedVnetName = $VnetId.Split('/')[-1]
        # Get vnet 
        $LinkedVNet = Get-AzVirtualNetwork -ResourceGroupName ($VnetId.Split('/')[4]) -Name ($VnetId.Split('/')[-1])
        # check that vnet is in same azure region as storage account, or in a paired azure region
        if ($LinkedVNet.Location -ne $NmeRegion) {
            Write-Output "VNet $LinkedVnetName is not in the same region as the storage account or a paired region. Cannot create private endpoint"
            Write-Warning "VNet $LinkedVnetName is not in the same region as the storage account or a paired region. Cannot create private endpoint"
            continue
            
        }
        
        # get subnets
        $SubnetNames = $LinkedVnets | Where-Object { $_.NetworkId -eq $VnetId } | Select-Object -ExpandProperty Subnet 
        # select the first subnet that's name is in the list of $SubnetNames
        $FirstSubnet = $LinkedVnet.Subnets | Sort-Object {$_.Name} | Where-Object { $SubnetNames -contains $_.Name } | Select -first 1
        # add a private endpoint for the cssa storage account in the linked vnet
        $CssaStoragePrivateEndpoint = $ExistingPrivateEndpoints | Where-Object { $_.PrivateLinkServiceConnections.PrivateLinkServiceId -eq $Sa.Id -and $_.Subnet.Id -like "*$($VnetId.Split('/')[-1])/*" }
        if ($CssaStoragePrivateEndpoint) {
            Write-Output "Found CSSA storage private endpoint for vnet $LinkedVnetName"
            continue
        }

        Write-Output "Configuring CSSA storage service connection and private endpoint for vnet $LinkedVnetName"
        $CssaStorageServiceConnection = New-AzPrivateLinkServiceConnection -Name "$CssaStorageServiceConnectionName-$($VnetId.Split('/')[-1])" -PrivateLinkServiceId $Sa.Id -GroupId "blob"
        $CssaStoragePrivateEndpoint = New-AzPrivateEndpoint -Name "$CssaStorageServiceConnectionName-$($VnetId.Split('/')[-1])" -ResourceGroupName $NmeRg -Location $NmeRegion -Subnet $FirstSubnet -PrivateLinkServiceConnection $CssaStorageServiceConnection
        # check if cssa storage account dns zone group 
        if ($SkipDNS -ne 'True') {
            # check if vnet already linked to private dns zone


            $CssaStorageDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $CssaStoragePrivateEndpoint.Name -ErrorAction SilentlyContinue
            if ($CssaStorageDnsZoneGroup) {
                Write-Output "Found CSSA storage DNS zone group for vnet $LinkedVnetName"
            } else {
                Write-Output "Configuring CSSA storage DNS zone group for vnet $LinkedVnetName"
                $Config = New-AzPrivateDnsZoneConfig -Name $StorageDnsZoneName -PrivateDnsZoneId $StorageDnsZone.ResourceId
                $CssaStorageDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$CssaStorageServiceConnectionName-$($VnetId.Split('/')[-1])" -Name "$SaStoragePrivateDnsZoneGroupName-$($VnetId.Split('/')[-1])" -PrivateDnsZoneConfig $config
            }
        } else {
            Write-Output "Skipping CSSA storage DNS zone group configuration for vnet $LinkedVnetName (SkipDNS enabled)"
        }
    }

}

# if cssastorage account is 'Restricted' add service endpoints to each linked subnet
elseif ($CssaStorageAccount -eq 'Restricted') {
    $LinkedVnets = GetVnets
    $Locations = Get-AzLocation 
    foreach ($VnetId in ($LinkedVnets.NetworkId | select -unique)) {
        # Get vnet 
        $LinkedVNet = Get-AzVirtualNetwork -ResourceGroupName ($VnetId.Split('/')[4]) -Name ($VnetId.Split('/')[-1])
        $VnetName = $VnetId.Split('/')[-1]
        # check that vnet is in same azure region as storage account, or in a paired azure region
        $Location = Get-AzLocation 
        if ($LinkedVNet.Location -eq $NmeRegion -or ($Location | where location -eq $NmeRegion | Select PairedRegion -ExpandProperty PairedRegion | Select Name -ExpandProperty Name) -eq $LinkedVNet.Location) {
            # add service endpoint
            Write-Output "VNet $VNetName is in the same region as the storage account or a paired region. Adding service endpoint."
            # get subnets
            $SubnetNames = $LinkedVnets | Where-Object { $_.NetworkId -eq $VnetId } | Select-Object -ExpandProperty Subnet 
            foreach ($SubnetName in $SubnetNames) {
                $Subnet = Get-AzVirtualNetworkSubnetConfig -Name $SubnetName -VirtualNetwork $LinkedVNet
                if ($Subnet.ServiceEndpoints -contains 'Microsoft.Storage') {
                    Write-Output "Service endpoint already exists on subnet $SubnetName in vnet $VNetName"
                } else {
                    Write-Output "Adding service endpoint to subnet $SubnetName in vnet $VNetName"
                    $LinkedVNet = $LinkedVNet | Set-AzVirtualNetworkSubnetConfig -Name $SubnetName -AddressPrefix $Subnet.AddressPrefix -ServiceEndpoint 'Microsoft.Storage' | Set-AzVirtualNetwork
                }
            }
        }
        else {
            # add global endpoint
            Write-Output "VNet $VNetName is not in the same region as the storage account or a paired region. Adding global endpoint."
            # get subnets
            $SubnetNames = $LinkedVnets | Where-Object { $_.NetworkId -eq $VnetId } | Select-Object -ExpandProperty Subnet 
            foreach ($SubnetName in $SubnetNames) {
                $Subnet = Get-AzVirtualNetworkSubnetConfig -Name $SubnetName -VirtualNetwork $LinkedVNet
                if ($Subnet.ServiceEndpoints.Service -contains 'Microsoft.Storage.Global') {
                    Write-Output "Service endpoint already exists on subnet $SubnetName in vnet $VNetName"
                } else {
                    Write-Output "Adding global service endpoint to subnet $SubnetName in vnet $VNetName"
                    $LinkedVNet = $LinkedVNet | Set-AzVirtualNetworkSubnetConfig -Name $SubnetName -AddressPrefix $Subnet.AddressPrefix -ServiceEndpoint 'Microsoft.Storage.Global' | Set-AzVirtualNetwork
                }
            }
        }

    }
}


#endregion

# region create private link peering
if ($PeerVnetIds) {
    Write-Output "Peering vnets" 
    $VNet = Get-AzVirtualNetwork -Name $PrivateLinkVnetName 
    if ($PeerVnetIds -eq 'All') {
        $VnetIds = GetVnets | Select-Object -ExpandProperty NetworkId
    }
    else {
        $VnetIds = $PeerVnetIds -split ','
    }
    foreach ($id in $VnetIds) {
        Write-Output "Peering with vnet $id"
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
    }
}
#endregion


#region app service vnet integration

Write-Output "Add VNet service endpoints"
$VNet = Get-AzVirtualNetwork -Name $PrivateLinkVnetName 
$PrivateEndpointSubnet = Get-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -VirtualNetwork $VNet
$AppServiceSubnet = Get-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -VirtualNetwork $VNet 

$ServiceEndpoints = @('Microsoft.KeyVault', 'Microsoft.Sql', 'Microsoft.Web')
if ($CssaStorageAccount -eq 'Private' -or $CssaStorageAccount -eq 'Restricted') {
    $ServiceEndpoints += 'Microsoft.Storage'
}


if ($privateendpointsubnet.ServiceEndpoints.service){
    if (!(Compare-Object $privateendpointsubnet.ServiceEndpoints.service -DifferenceObject $serviceEndpoints -ErrorAction SilentlyContinue)) {
        Write-Output "Found service endpoints"
    } else {
        Write-Output "Adding service endpoints"
        $VNet = $VNet | Set-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -AddressPrefix $PrivateEndpointSubnet.AddressPrefix -ServiceEndpoint $ServiceEndpoints -PrivateEndpointNetworkPoliciesFlag Disabled | Set-AzVirtualNetwork
    }
}
else {
    Write-Output "Adding service endpoints"
    $VNet = $VNet | Set-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -AddressPrefix $PrivateEndpointSubnet.AddressPrefix -ServiceEndpoint $ServiceEndpoints -PrivateEndpointNetworkPoliciesFlag Disabled | Set-AzVirtualNetwork 

}
# enable network policy
$PrivateEndpointSubnet = Get-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -VirtualNetwork $VNet
if ($PrivateEndpointSubnet.PrivateEndpointNetworkPolicies -eq 'Enabled') {
    Write-Output "Network policies already enabled"
} else {
    Write-Output "Enabling network policies"
    try {
        $Vnet = $VNet | Set-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -AddressPrefix $PrivateEndpointSubnet.AddressPrefix -ServiceEndpoint $ServiceEndpoints -PrivateEndpointNetworkPoliciesFlag Enabled | Set-AzVirtualNetwork
    }
    catch {
        # sometimes can't enable network policies on subnet with private endpoints, e.g. in gov cloud
        Write-Output "Enabling network policies failed, setting to disabled"
        $Vnet = $VNet | Set-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -AddressPrefix $PrivateEndpointSubnet.AddressPrefix -ServiceEndpoint $ServiceEndpoints -PrivateEndpointNetworkPoliciesFlag Disabled | Set-AzVirtualNetwork 
    }
}


$VNet = Get-AzVirtualNetwork -Name $PrivateLinkVnetName 
$AppServiceSubnet = Get-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -VirtualNetwork $VNet

# Check if subnet delegation created
$AppSubnetDelegation = Get-AzDelegation -Subnet $AppServiceSubnet -ErrorAction SilentlyContinue
if ($AppSubnetDelegation.ServiceName -eq 'Microsoft.Web/serverFarms') {
    Write-Output "App service subnet delegation already created"
} 
else {
    Write-Output "Delegate app service subnet to webfarms"
    $AppServiceSubnet | Add-AzDelegation -Name $WebAppSubnetDelegationName -ServiceName "Microsoft.Web/serverFarms" | Out-Null
    $vnet = Set-AzVirtualNetwork -VirtualNetwork $VNet
}

$webApp = Get-AzResource -Id $NmeWebApp.id 
# check if vnet integration enabled
if ($webApp.Properties.virtualNetworkSubnetId -eq $AppServiceSubnet.id) {
    Write-Output "App service VNet integration already enabled"
} 
else {
    Write-Output "Enabling app service VNet integration"
    $webApp.Properties.virtualNetworkSubnetId = $AppServiceSubnet.id
    $webApp.Properties.vnetRouteAllEnabled = 'false'
    $webApp.Properties.publicNetworkAccess = "Enabled"
    $WebApp = $webApp | Set-AzResource -Force
}

if ($NmeCclWebAppName) {
    $NmeCclWebApp = Get-AzWebApp -ResourceGroupName $NmeRg -Name $NmeCclWebAppName
    $CclWebApp = Get-AzResource -Id $NmeCclWebApp.id 
    # check if endpoint integration enabled
    if ($CclWebApp.Properties.virtualNetworkSubnetId -eq $AppServiceSubnet.id) {
        Write-Output "CCL App service VNet integration already enabled"
    } 
    else {
        Write-Output "Enabling CCL app service VNet integration"
        $CclWebApp.Properties.virtualNetworkSubnetId = $AppServiceSubnet.id
        $CclWebApp.Properties.vnetRouteAllEnabled = 'false'
        $CclWebApp = $CclWebApp | Set-AzResource -Force
    }
}

# check if $NmeIiWebAppName exists
if ($NmeIiWebAppName) {
    $NmeIiWebApp = Get-AzWebApp -ResourceGroupName $NmeRg -Name $NmeIiWebAppName
    $IiwWebApp = Get-AzResource -Id $NmeIiWebApp.id 
    # check if endpoint integration enabled
    if ($IiwWebApp.Properties.virtualNetworkSubnetId -eq $AppServiceSubnet.id) {
        Write-Output "Intune Insights App service VNet integration already enabled"
    } 
    else {
        Write-Output "Enabling Intune Insights app service VNet integration"
        $IiwWebApp.Properties.virtualNetworkSubnetId = $AppServiceSubnet.id
        $IiwWebApp.Properties.vnetRouteAllEnabled = 'false'
        $IiwWebApp = $IiwWebApp | Set-AzResource -Force
    }
}
# check if real time insights web app exists
if ($NmeRtiWebAppName) {
    $NmeRtiWebApp = Get-AzWebApp -ResourceGroupName $NmeRg -Name $NmeRtiWebAppName
    $RtiWebApp = Get-AzResource -Id $NmeRtiWebApp.id 
    # check if endpoint integration enabled
    if ($RtiWebApp.Properties.virtualNetworkSubnetId -eq $AppServiceSubnet.id) {
        Write-Output "RTI App service VNet integration already enabled"
    } 
    else {
        Write-Output "Enabling RTI app service VNet integration"
        $RtiWebApp.Properties.virtualNetworkSubnetId = $AppServiceSubnet.id
        $RtiWebApp.Properties.vnetRouteAllEnabled = 'false'
        $RtiWebApp = $RtiWebApp | Set-AzResource -Force
    }
}
# enable network policy
$AppServiceSubnet = Get-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -VirtualNetwork $VNet
$VNet = Get-AzVirtualNetwork -Name $PrivateLinkVnetName 

if ($AppServiceSubnet.PrivateEndpointNetworkPolicies -eq 'Enabled') {
    Write-Output "Network policies already enabled"
} else {
    Write-Output "Enabling network policies"
    #$Vnet = $VNet | Set-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -AddressPrefix $AppServiceSubnet.addressprefix -PrivateEndpointNetworkPoliciesFlag Enabled | Set-AzVirtualNetwork
    
}
#endregion

#region make resources private

Write-Output "Check network deny rules for key vault and sql"
$NmeKeyVault = Get-AzKeyVault -ResourceGroupName $NmeRg -VaultName $KeyVaultName
# check if deny rule for key vault exists
if (($NmeKeyVault.NetworkAcls.DefaultAction -eq 'Deny') -and ($NmeKeyVault.PublicNetworkAccess -eq 'Disabled')) {
    Write-Output "Key vault public access already disabled"
}
else {
    Write-Output "Disabling key vault public access"
    Add-AzKeyVaultNetworkRule -VaultName $NmeKeyVault.VaultName -VirtualNetworkResourceId $PrivateEndpointSubnet.id -ResourceGroupName $NmeRg 
    Update-AzKeyVaultNetworkRuleSet -VaultName $NmeKeyVault.VaultName -Bypass None -ResourceGroupName $NmeRg
    update-AzKeyVaultNetworkRuleSet -VaultName $NmeKeyVault.VaultName -DefaultAction Deny -ResourceGroupName $NmeRg
    Update-AzKeyVault -ResourceGroupName $NmeRg -VaultName $NmeKeyVault.VaultName -PublicNetworkAccess 'Disabled' | out-null
}
if ($NmeCclKeyVaultName) {
    $NmeCclKeyVault = Get-AzKeyVault -ResourceGroupName $NmeRg -VaultName $NmeCclKeyVaultName
    # check if deny rule for key vault exists
    if (($NmeCclKeyVault.NetworkAcls.DefaultAction -eq 'Deny') -and ($NmeCclKeyVault.PublicNetworkAccess -eq 'Disabled')) {
        Write-Output "CCL Key vault public access already disabled"
    }
    else {
        Write-Output "Disabling CCL key vault public access"
        Add-AzKeyVaultNetworkRule -VaultName $NmeCclKeyVault.VaultName -VirtualNetworkResourceId $PrivateEndpointSubnet.id -ResourceGroupName $NmeRg 
        Update-AzKeyVaultNetworkRuleSet -VaultName $NmeCclKeyVault.VaultName -Bypass None -ResourceGroupName $NmeRg
        update-AzKeyVaultNetworkRuleSet -VaultName $NmeCclKeyVault.VaultName -DefaultAction Deny -ResourceGroupName $NmeRg
        Update-AzKeyVault -ResourceGroupName $NmeRg -VaultName $NmeCclKeyVault.VaultName -PublicNetworkAccess 'Disabled' | Out-Null
    }
}

# check if deny rule for sql exists
$SqlServer = Get-AzSqlServer -ResourceGroupName $NmeRg -ServerName $NmeSqlServerName
$ServerRules = Get-AzSqlServerVirtualNetworkRule -ServerName $NmeSqlServerName -ResourceGroupName $NmeRg 
if ($SqlServer.PublicNetworkAccess -eq 'Disabled') {
    Write-Output "SQL public access already disabled"
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

if ($CssaStorageAccount -eq 'Private' ) {
    # check if deny rule for storage exists
    $StorageAccount = Get-AzStorageAccount -ResourceGroupName $NmeRg | Where-Object StorageAccountName -Match 'cssa'
    if ($StorageAccount.PublicNetworkAccess -eq 'Disabled') {
        Write-Output "CSSA storage public access is already disabled"
    }
    else {
        Write-Output "Disabling CSSA storage public access"
        Set-AzStorageAccount -PublicNetworkAccess Disabled -ResourceGroupName $NmeRg -Name $StorageAccount.StorageAccountName | Out-Null
    }
}
elseif ($cssastorageaccount -eq 'Restricted') {
    # keep storage account public but add network rules to allow access from 'All' Vnets linked to NME
    $VNet = Get-AzVirtualNetwork -Name $PrivateLinkVnetName 
    $VnetIds = $LinkedVnets.NetworkId | select -unique
    # if no vnets, warn that no vnets will be added to storage account network rules
    if (!$VnetIds) {
        Write-Warning "No linked vnets found to add to storage account network rules. Cssa storage account will not be accessible from AVD networks."
        Write-Output "No linked vnets found to add to storage account network rules. Cssa storage account will not be accessible from AVD networks."
    }
    else {
        $NmeStorageAccount = Get-AzStorageAccount -ResourceGroupName $NmeRg | Where-Object StorageAccountName -eq $NmeScriptedActionStorageAccountName
        Write-Output "Configuring cssa storage account network rules"
        # add vnet rules for each linked vnet
        foreach ($id in $VnetIds) {
            # get the vnet
            $ThisVnet = Get-AzvirtualNetwork -Name (Get-AzResource -ResourceId $id).Name -ResourceGroupName (Get-AzResource -ResourceId $id).ResourceGroupName
            # add all subnets to network rules
            foreach ($subnet in $ThisVnet.Subnets) {
                Write-Output "Adding subnet $($subnet.Name) from vnet $($ThisVnet.Name) to cssa storage account network rules"
                $rule = Add-AzStorageAccountNetworkRule -ResourceGroupName $NmeRg -Name $NmeStorageAccount.StorageAccountName -VirtualNetworkResourceId $Subnet.id
            }
        }
        # set default action to deny
        write-output "Setting default action to Deny for cssa storage account"
        Update-AzStorageAccountNetworkRuleSet -ResourceGroupName $NmeRg -Name $NmeStorageAccount.StorageAccountName -DefaultAction Deny -Bypass None | Out-Null
    }
    
}

# make ccl storage account private
if ($NmeCclStorageAccountName) {
    $NmeCclStorageAccount = Get-AzStorageAccount -ResourceGroupName $NmeRg -Name $NmeCclStorageAccountName
    if ($NmeCclStorageAccount.PublicNetworkAccess -eq 'Disabled') {
        Write-Output "CCL Storage public access is already disabled"
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
        Write-Output "DPS Storage public access is already disabled"
    }
    else {
        Write-Output "Disabling DPS storage public access"
        Set-AzStorageAccount -PublicNetworkAccess Disabled -ResourceGroupName $NmeRg -Name $NmeDpsStorageAccount.StorageAccountName | Out-Null
    }
}
# make real time insights resources private
if ($NmeRtiStorageAccountName) {
    $NmeRtiStorageAccount = Get-AzStorageAccount -ResourceGroupName $NmeRg -Name $NmeRtiStorageAccountName
    if ($NmeRtiStorageAccount.PublicNetworkAccess -eq 'Disabled') {
        Write-Output "RTI Storage public access is already disabled"
    }
    else {
        Write-Output "Disabling RTI storage public access"
        Set-AzStorageAccount -PublicNetworkAccess Disabled -ResourceGroupName $NmeRg -Name $NmeRtiStorageAccount.StorageAccountName | Out-Null
    }
}
if ($NmeRtiSqlServerName) {
    $RtiSqlServer = Get-AzSqlServer -ResourceGroupName $NmeRg -ServerName $NmeRtiSqlServerName
    $RtiServerRules = Get-AzSqlServerVirtualNetworkRule -ServerName $NmeRtiSqlServerName -ResourceGroupName $NmeRg 
    if ($RtiSqlServer.PublicNetworkAccess -eq 'Disabled') {
        Write-Output "RTI SQL public access already disabled"
    }
    else {
        Write-Output "Disabling RTI SQL public access"
        if ($RtiServerRules.VirtualNetworkSubnetId -notcontains $PrivateEndpointSubnet.id){
            $PrivateEndpointRule = New-AzSqlServerVirtualNetworkRule -VirtualNetworkRuleName 'Allow private endpoint subnet' -VirtualNetworkSubnetId $PrivateEndpointSubnet.id -ServerName $NmeRtiSqlServerName -ResourceGroupName $NmeRg
        }
        # New-AzSqlServerVirtualNetworkRule -VirtualNetworkRuleName 'Allow app service subnet' -VirtualNetworkSubnetId $AppServiceSubnet.id -ServerName $NmeRtiSqlServerName -ResourceGroupName $NmeRg
        if ($RtiSqlServer.PublicNetworkAccess -eq 'Enabled'){

            try {
                $DenyPublicSql = Set-AzSqlServer -ServerName $NmeRtiSqlServerName -ResourceGroupName $NmeRg -PublicNetworkAccess Disabled
            }
            catch {
                try {
                    if ($RtiSqlServer.Administrators.Sid.guid -eq $RtiSqlServer.Administrators.login) {
                        # workaround for app id set as admin
                        $AppName = GetEntAppName
                        Set-AzSqlServerActiveDirectoryAdministrator -ResourceGroupName $NmeRg -ServerName $NmeRtiSqlServerName -DisplayName $AppName
                        $DenyPublicSql = Set-AzSqlServer -ServerName $NmeRtiSqlServerName -ResourceGroupName $NmeRg -PublicNetworkAccess Disabled
                    }
                    else {
                        Write-Output "Disabling RTI SQL public network access failed. Disable in Azure Portal"
                        write-output $_
                        Write-Warning "Disabling RTI SQL public network access failed. Disable in Azure Portal"
                    }
                }
                catch {   
                    Write-Output "Disabling RTI SQL public network access failed. Disable in Azure Portal"
                    write-output $_
                    Write-Warning "Disabling RTI SQL public network access failed. Disable in Azure Portal"
                }
            }
        }
    }
}
if ($NmeRtiKeyVaultName) {
    $RtiKeyVault = Get-AzKeyVault -ResourceGroupName $NmeRg -VaultName $NmeRtiKeyVaultName
    # check if deny rule for key vault exists
    if (($RtiKeyVault.NetworkAcls.DefaultAction -eq 'Deny') -and ($RtiKeyVault.PublicNetworkAccess -eq 'Disabled')) {
        Write-Output "RTI Key vault public access already disabled"
    }
    else {
        Write-Output "Disabling RTI key vault public access"
        Add-AzKeyVaultNetworkRule -VaultName $RtiKeyVault.VaultName -VirtualNetworkResourceId $PrivateEndpointSubnet.id -ResourceGroupName $NmeRg 
        Update-AzKeyVaultNetworkRuleSet -VaultName $RtiKeyVault.VaultName -Bypass None -ResourceGroupName $NmeRg
        update-AzKeyVaultNetworkRuleSet -VaultName $RtiKeyVault.VaultName -DefaultAction Deny -ResourceGroupName $NmeRg
        Update-AzKeyVault -ResourceGroupName $NmeRg -VaultName $RtiKeyVault.VaultName -PublicNetworkAccess 'Disabled' | out-null
    }
}

# make intune insights key vault private
if ($NmeIiKeyVaultName) {
    $IiKeyVault = Get-AzKeyVault -ResourceGroupName $NmeRg -VaultName $NmeIiKeyVaultName
    # check if deny rule for key vault exists
    if (($IiKeyVault.NetworkAcls.DefaultAction -eq 'Deny') -and ($IiKeyVault.PublicNetworkAccess -eq 'Disabled')) {
        Write-Output "Intune Insights Key vault public access already disabled"
    }
    else {
        Write-Output "Disabling Intune Insights key vault public access"
        Add-AzKeyVaultNetworkRule -VaultName $IiKeyVault.VaultName -VirtualNetworkResourceId $PrivateEndpointSubnet.id -ResourceGroupName $NmeRg 
        Update-AzKeyVaultNetworkRuleSet -VaultName $IiKeyVault.VaultName -Bypass None -ResourceGroupName $NmeRg
        update-AzKeyVaultNetworkRuleSet -VaultName $IiKeyVault.VaultName -DefaultAction Deny -ResourceGroupName $NmeRg
        Update-AzKeyVault -ResourceGroupName $NmeRg -VaultName $IiKeyVault.VaultName -PublicNetworkAccess 'Disabled' | out-null
    }
}
# make intune insights sql server private
if ($NmeIiSqlServerName) {
    $IiSqlServer = Get-AzSqlServer -ResourceGroupName $NmeRg -ServerName $NmeIiSqlServerName
    $IiServerRules = Get-AzSqlServerVirtualNetworkRule -ServerName $NmeIiSqlServerName -ResourceGroupName $NmeRg 
    if ($IiSqlServer.PublicNetworkAccess -eq 'Disabled') {
        Write-Output "Intune Insights SQL public access already disabled"
    }
    else {
        Write-Output "Disabling Intune Insights SQL public access"
        if ($IiServerRules.VirtualNetworkSubnetId -notcontains $PrivateEndpointSubnet.id){
            $PrivateEndpointRule = New-AzSqlServerVirtualNetworkRule -VirtualNetworkRuleName 'Allow private endpoint subnet' -VirtualNetworkSubnetId $PrivateEndpointSubnet.id -ServerName $NmeIiSqlServerName -ResourceGroupName $NmeRg
        }
        # New-AzSqlServerVirtualNetworkRule -VirtualNetworkRuleName 'Allow app service subnet' -VirtualNetworkSubnetId $AppServiceSubnet.id -ServerName $NmeIiSqlServerName -ResourceGroupName $NmeRg
        if ($IiSqlServer.PublicNetworkAccess -eq 'Enabled'){
            try {
                $DenyPublicSql = Set-AzSqlServer -ServerName $NmeIiSqlServerName -ResourceGroupName $NmeRg -PublicNetworkAccess "Disabled"
            }
            catch {
                try {
                    if ($IiSqlServer.Administrators.Sid.guid -eq $IiSqlServer.Administrators.login) {
                        # workaround for app id set as admin
                        $AppName = GetEntAppName
                        Set-AzSqlServerActiveDirectoryAdministrator -ResourceGroupName $NmeRg -ServerName $NmeIiSqlServerName -DisplayName $AppName
                        $DenyPublicSql = Set-AzSqlServer -ServerName $NmeIiSqlServerName -ResourceGroupName $NmeRg -PublicNetworkAccess Disabled
                    }
                    else {
                        Write-Output "Disabling Intune Insights SQL public network access failed. Disable in Azure Portal"
                        write-output $_
                        Write-Warning "Disabling Intune Insights SQL public network access failed. Disable in Azure Portal"
                    }
                }
                catch {   
                    Write-Output "Disabling Intune Insights SQL public network access failed. Disable in Azure Portal"
                    write-output $_
                    Write-Warning "Disabling Intune Insights SQL public network access failed. Disable in Azure Portal"
                }
            }
        }
    }
}


#endregion

$webApp = Get-AzResource -Id $NmeWebApp.id 
if ($MakeAppServicePrivate -eq 'True') {
    Write-Output "Disabling NME app service public access"
    $webApp.Properties.publicNetworkAccess = "Disabled"
    $webApp | Set-AzResource -Force | Out-Null
}
else {
    $webApp.Properties.publicNetworkAccess = "Enabled"
    $webApp | Set-AzResource -Force | Out-Null
}

# restart the app service
Write-Output "Restarting app service"
$restart = Restart-AzWebApp -ResourceGroupName $NmeRg -Name $NmeWebApp.Name