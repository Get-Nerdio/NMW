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
to be peered to the new private network. Note that MakeAppServicePrivate governs the primary Nerdio Manager app service
only. If the Cost Calculator (CCL) is deployed, its web app is always made private, regardless of this parameter: the
only thing that communicates with it is the primary Nerdio Manager web app, over the private network. The Intune
Insights and Real Time Insights web apps get private endpoints but are not made private by this script.

This script never re-enables public network access on anything. Setting MakeAppServicePrivate back to 'false' on a
later run leaves the app service private; re-enable public access in the Azure Portal if that is what you want.

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
  "MakeSaStoragePrivate": {
    "Description": "Make the scripted actions storage account private. AVD hosts require access to the scripted actions storage account, so making this storage account private will require peering the AVD VNets to the NME private VNet or using additional private endpoints to put the scripted actions storage account on the AVD VNets as well as the NME private VNet.",
    "IsRequired": false,
    "DefaultValue": "false"
  },
  "PeerVnetIds": {
    "Description": "Optional. Values are 'All' or comma-separated list of Azure resource IDs of VNets to peer to private endpoint VNet. If 'All' then all linked VNets will be peered. The VNETs or their resource groups must be linked to Nerdio Manager in Settings->Azure environment. All VNets must be in the same subscription as Nerdio Manager. External VNets must be peered manually.",
    "IsRequired": false,
    "DefaultValue": ""
  },
  "MakeAppServicePrivate": {
    "Description": "WARNING: If set to true, only hosts on the VNet created by this script, or on peered VNets, will be able to access the app service URL. Note that setting this back to false does NOT re-enable public access on a later run - this script never re-enables public network access implicitly. To undo it, re-enable public network access on the app service in the Azure Portal.",
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
    # NMW_RESOURCE is NOT part of NME's own deployment tagging scheme - it's a convention specific to this
    # Enable Private Endpoints script, used only as a last-resort fallback to disambiguate a resource that the
    # tag- and name-based checks below couldn't reliably identify. When none of those checks find a resource,
    # this script tells the user to manually add this tag (with the expected value) to the correct resource so
    # that the *next* run can find it here.
    $NmeResourceTagName = "NMW_RESOURCE"
    $keyvaultTags = $NmeKeyVault.Tags
    # $key becomes the name of this deployment's "_OBJECT_TYPE" tag (e.g. "NMW_OBJECT_TYPE"), found by looking
    # for whichever tag on the NME key vault has the value "PAAS" - this makes the lookup work regardless of the
    # actual tag prefix, since the prefix (almost always "NMW") is configurable per deployment and is stored in
    # the NME web app's "Deployment:AzureTagPrefix" app setting (captured below as $NmeTagPrefix).
    # Use -ExpandProperty Key (not Name) on both lookups: Name only works on the key vault lookup by
    # accident, since PowerShell's extended type system aliases Name->Key on DictionaryEntry (what a
    # Hashtable enumerates as) but not on KeyValuePair<string,string> (what the Az storage account's
    # Tags dictionary enumerates as). Key is a real property on both. -First 1 guards against a
    # resource carrying two tags with the same value producing an array in $key.
    $key = $keyvaultTags.GetEnumerator() | Where-Object { $_.Value -eq "PAAS" } | Select-Object -ExpandProperty Key -First 1
    if (!$key) {
        $ScriptedActionsStorageAccount = Get-AzStorageAccount -ResourceGroupName $NmeRg | Where-Object StorageAccountName -Match 'cssa'
        $key = $ScriptedActionsStorageAccount.Tags.GetEnumerator() | Where-Object { $_.Value -eq "CUSTOM_SCRIPTS_STORAGE_ACCOUNT" } | Select-Object -ExpandProperty Key -First 1
    }
    if (!$key) {
        # Neither discovery method found the tag name - fall back to the default rather than silently
        # skipping all $key-based discovery (CCL, Intune Insights, RTI, scripted-actions storage, etc).
        Write-Verbose "Could not derive the object-type tag name from the key vault or scripted actions storage account tags. Assuming the default 'NMW_OBJECT_TYPE'."
        $key = 'NMW_OBJECT_TYPE'
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
    }
    # Validate and assign for both the tag-based and fallback lookups. This assignment used to live
    # inside the fallback block, which left $NmeSqlServerName null whenever the PRIMARY_SQL_SERVER
    # tag was found.
    if (@($SqlServer).Count -ne 1) {
        Throw "Unable to find NME sql server. Please add the tag '$NmeResourceTagName' with value 'PRIMARY_SQL_SERVER' to the primary sql server used by Nerdio Manager and rerun this script."
    }
    $script:NmeSqlServerName = @($SqlServer)[0].ServerName
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

    Write-Verbose "Getting Scripted Actions Storage Account"
    # Check, in order: 1) the actual NME deployment tag ($key - normally "NMW_OBJECT_TYPE", but the prefix
    # depends on this deployment's Deployment:AzureTagPrefix setting, so $key is used instead of a hardcoded
    # name); 2) the "cssa" naming convention used by NME when it creates this storage account; 3) this script's
    # own 'NMW_RESOURCE' fallback tag, for cases where a customer had to manually tag an ambiguous or
    # differently-named storage account after being warned by a previous run.
    if ($key) {
        $script:NmeScriptedActionsStorageAccountName = Get-AzStorageAccount -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue | Where-Object { $_.Tags[$key] -eq 'CUSTOM_SCRIPTS_STORAGE_ACCOUNT' } | Select-Object -ExpandProperty StorageAccountName
    }
    if (!$script:NmeScriptedActionsStorageAccountName) {
        Write-Verbose "Scripted actions storage account not found by tag, trying by name pattern"
        $script:NmeScriptedActionsStorageAccountName = Get-AzStorageAccount -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue | Where-Object { $_.StorageAccountName -match 'cssa' } | Select-Object -ExpandProperty StorageAccountName
    }
    if (!$script:NmeScriptedActionsStorageAccountName) {
        Write-Verbose "Scripted actions storage account not found by name pattern, trying '$NmeResourceTagName' fallback tag"
        $script:NmeScriptedActionsStorageAccountName = Get-AzStorageAccount -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue | Where-Object { $_.tags[$NmeResourceTagName] -eq 'CUSTOM_SCRIPTS_STORAGE_ACCOUNT' } | Select-Object -ExpandProperty StorageAccountName
    }
    if ($script:NmeScriptedActionsStorageAccountName.count -ne 1) {
        Write-Warning "Unable to find the scripted actions storage account. Please add the tag '$NmeResourceTagName' with value 'CUSTOM_SCRIPTS_STORAGE_ACCOUNT' to the scripted actions storage account (its name usually contains 'cssa') used by Nerdio Manager and rerun this script."
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
    # These lookups are for optional components: a failed tag lookup is expected to fall through to the
    # next discovery method, so the exception is intentionally swallowed here. It is still surfaced on the
    # verbose stream so a throttling error or RBAC denial can be told apart from "not deployed".
    try {
        $NmeAppInsights = Get-AzApplicationInsights -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue | Where-Object {$_.tag[$NmeResourceTagName] -eq 'NERDIO_MANAGER_APPINSIGHTS' }
    } catch { Write-Verbose "Lookup of NME Application Insights by tag failed: $($_.Exception.Message)" }
    if (!$NmeAppInsights) {
        Write-Verbose "NME App Insights not found by tag, trying by instrumentation key"
        $NmeAppInsights = Get-AzApplicationInsights -ResourceGroupName $NmeRg | Where-Object { $_.InstrumentationKey -eq ($NmeWebApp.siteconfig.appsettings | Where-Object  {$_.name -eq 'ApplicationInsights:InstrumentationKey'} | Select-Object -ExpandProperty value) }
    }
    if ($NmeAppInsights.count -ne 1) {
        throw "Unable to find NME App Insights. Please add the tag '$NmeResourceTagName' with value 'NERDIO_MANAGER_APPINSIGHTS' to the Nerdio Manager Application Insights resource and rerun this script."
    }
    $script:NmeAppInsightsName = $NmeAppInsights.name
    $script:NmeAppServicePlanName = $NmeWebApp.ServerFarmId.Split("/")[-1]
    $script:NmeSubscriptionId = ($NmeWebApp.siteconfig.appsettings | Where-Object name -eq 'Deployment:SubscriptionId').value
    $script:NmeTagPrefix = ($NmeWebApp.siteconfig.appsettings | Where-Object name -eq 'Deployment:AzureTagPrefix').value
    $script:NmeAutomationAccountName = ($NmeWebApp.siteconfig.appsettings | Where-Object name -eq 'Deployment:AutomationAccountName').value
    $script:NmeScriptedActionsAccountName = (($NmeWebApp.siteconfig.appsettings | Where-Object name -eq 'Deployment:ScriptedActionAccount').value).Split("/")[-1]
    $script:NmeRegion = $NmeKeyVault.Location

    # Find Real Time Insights components if they exist
    # Find RTI sql server
    try {$RtiSqlServer = Get-AzSqlServer -ResourceGroupName $nmerg | Where-Object {$_.tags[$NmeResourceTagName] -eq 'REAL_TIME_INSIGHTS_SQL_SERVER'}}
    catch { Write-Verbose "Lookup of Real Time Insights SQL server by tag failed: $($_.Exception.Message)" }
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
    } catch { Write-Verbose "Lookup of Real Time Insights web app by tag failed: $($_.Exception.Message)" }
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
    } catch { Write-Verbose "Lookup of Real Time Insights key vault by tag failed: $($_.Exception.Message)" }
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
    } catch { Write-Verbose "Lookup of Real Time Insights storage account by tag failed: $($_.Exception.Message)" }
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
$SaStorageServiceConnectionName = "$Prefix-app-sa-storage-serviceconnection"
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

# define variables for private DNS zone links
$KeyVaultZoneLinkName = "$Prefix-vault-privatelink"
$SqlZoneLinkName = "$Prefix-database-privatelink"
$BlobZoneLinkName = "$prefix-blob-privatelink"
$AutomationZoneLinkName = "$prefix-automation-privatelink"
$AppServiceZoneLinkName = "$Prefix-app-appservice-privatelink"
$FileStoragePrivateDnsZoneLinkName = "$Prefix-filestorage-privatelink"
$BlobStoragePrivateDnsZoneLinkName = "$Prefix-blobstorage-privatelink"
$RtiTableStoragePrivateDnsZoneLinkName = "$Prefix-rti-tablestorage-privatelink"

# Define variables for all DNS zone names
if ($NmeWebApp.DefaultHostName -match "azurewebsites.us") {
    $KeyVaultDnsZoneName = "privatelink.vaultcore.usgovcloudapi.net"
    $SqlDnsZoneName = "privatelink.database.usgovcloudapi.net"
    $AutomationDnsZoneName = "privatelink.azure-automation.us"
    $StorageDnsZoneName = "privatelink.blob.core.usgovcloudapi.net"
    $TableDnsZoneName = "privatelink.table.core.usgovcloudapi.net"
    $AppServiceDnsZoneName = "privatelink.azurewebsites.us"
    $AzureManagementApi = "management.usgovcloudapi.net"
} else {
    $KeyVaultDnsZoneName = "privatelink.vaultcore.azure.net"
    $SqlDnsZoneName = "privatelink.database.windows.net"
    $AutomationDnsZoneName = "privatelink.azure-automation.net"
    $StorageDnsZoneName = "privatelink.blob.core.windows.net"
    $TableDnsZoneName = "privatelink.table.core.windows.net"
    $AppServiceDnsZoneName = "privatelink.azurewebsites.net"
    $AzureManagementApi = 'management.azure.com'
}


# Looks up a job parameter by name, case-insensitively, since $job.JobParameters is a
# dictionary and NME's parameter casing can vary between execution modes.
function Get-NmeJobParameterValue {
    param($JobParameters, [string]$Name)
    if (-not $JobParameters) { return $null }
    foreach ($k in $JobParameters.Keys) {
        if ($k -ieq $Name) {
            # Automation stores job parameters as JSON, so a string value can come back wrapped in
            # double quotes depending on how it was submitted. Strip them - a stray quote would make
            # a base64 decode fail (and silently disable duplicate-run detection) or corrupt a URI.
            $Value = [string]$JobParameters[$k]
            return $Value.Trim().Trim('"')
        }
    }
    return $null
}

# Resolves the script text for a job in either execution mode: the newer inline mode
# (full script body passed as base64 in the ScriptBase64 job parameter) or the older
# download mode (script fetched from the scriptUri job parameter). If a future NME build
# double-encodes the base64 or uses a different parameter name/casing, this is the single
# place to adjust - verify the parameter shape against a real inline-mode job.
function Get-NmeJobScriptText {
    param($JobParameters)
    try {
        $ScriptBase64 = Get-NmeJobParameterValue -JobParameters $JobParameters -Name 'ScriptBase64'
        if ($ScriptBase64) {
            # Normalize URL-safe base64 (NME may or may not use it) before decoding.
            $Normalized = $ScriptBase64.Replace('-', '+').Replace('_', '/')
            while ($Normalized.Length % 4 -ne 0) { $Normalized += '=' }
            $Bytes = [System.Convert]::FromBase64String($Normalized)
            return [System.Text.Encoding]::UTF8.GetString($Bytes)
        }

        $ScriptUri = Get-NmeJobParameterValue -JobParameters $JobParameters -Name 'scriptUri'
        if ($ScriptUri) {
            $Response = Invoke-WebRequest -UseBasicParsing -Uri $ScriptUri
            if ($Response.Content -is [byte[]]) {
                return [System.Text.Encoding]::UTF8.GetString($Response.Content)
            }
            return [string]$Response.Content
        }

        return $null
    }
    catch {
        Write-Verbose "Get-NmeJobScriptText failed to resolve script text: $($_.Exception.Message)"
        return $null
    }
}

# Hashes script text after normalizing it, because the same script text can arrive with
# different encodings depending on how it was retrieved (UTF8 BOM, CRLF vs LF line endings,
# a trailing newline). An inline payload and the same script downloaded from storage are
# unlikely to be byte-identical, so hashing the raw bytes would silently never match and
# duplicate-run detection would look like it works while never actually triggering. Do not
# "simplify" this back to a plain file hash.
function Get-NmeScriptHash {
    param([string]$ScriptText)
    if ([string]::IsNullOrEmpty($ScriptText)) { return $null }

    $Normalized = $ScriptText
    if ($Normalized.Length -gt 0 -and $Normalized[0] -eq [char]0xFEFF) {
        $Normalized = $Normalized.Substring(1)
    }
    $Normalized = $Normalized.Replace("`r`n", "`n").Replace("`r", "`n")
    $Normalized = $Normalized.Trim()

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Normalized)
        return [System.BitConverter]::ToString($sha256.ComputeHash($bytes)).Replace('-', '')
    }
    finally { $sha256.Dispose() }
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
        $ThisScriptText = Get-NmeJobScriptText -JobParameters $ThisJob.JobParameters
        $ThisScriptHash = Get-NmeScriptHash -ScriptText $ThisScriptText
        if (-not $ThisScriptHash) {
            Write-Verbose "Skipping duplicate-run detection because the running script's source could not be determined."
            return
        }

        # EndTime is a DateTimeOffset; compare both sides in UTC explicitly rather than
        # relying on the sandbox's local timezone happening to be UTC.
        $JobCutoffUtc = (Get-Date).ToUniversalTime().AddMinutes(-$MinutesAgo)
        $jobs = Get-AzAutomationJob -ResourceGroupName $NmeRg -AutomationAccountName $NmeScriptedActionsAccountName |
            Where-Object { $_.Status -match 'completed|Failed' } |
            Where-Object { $_.EndTime.UtcDateTime -gt $JobCutoffUtc }
        foreach ($job in $jobs){
            $details = Get-AzAutomationJob -id $job.JobId -resourcegroupname $NmeRg -AutomationAccountName $NmeScriptedActionsAccountName
            $JobScriptText = Get-NmeJobScriptText -JobParameters $details.JobParameters
            $JobHash = Get-NmeScriptHash -ScriptText $JobScriptText
            if (-not $JobHash) {
                Write-Verbose "Skipping job $($job.JobId) because its script source could not be determined."
                continue
            }
            if ($JobHash -eq $ThisScriptHash){
                Write-Output "Output of previous script run:"
                $JobOutput = Get-AzAutomationJobOutput -Id $details.JobId -resourcegroupname $NmeRg -AutomationAccountName $NmeScriptedActionsAccountName
                $JobOutput | select summary -ExpandProperty summary

                Write-Output "App Service restarted after running this script."
                # How much of the cooldown window is left, based on how long ago the app was actually modified.
                $WaitMinutes = [math]::Ceiling($MinutesAgo - ((Get-Date).ToUniversalTime() - $app.LastModifiedTimeUtc).TotalMinutes)
                if ($WaitMinutes -gt 0) {
                    Write-Output "If you need to re-run the script, please wait $WaitMinutes minutes and try again."
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


# set resource group for dns zones
if ($SkipDNS -eq 'True') {
    Write-Output "SkipDNS is enabled - skipping all DNS zone operations"
    # Set DNS variables to null when skipping DNS operations
    $DnsRg = $null
    $KeyVaultDnsZone = $null
    $SqlDnsZone = $null
    $AutomationDnsZone = $null
    $StorageDnsZone = $null
    $TableDnsZone = $null
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
        if ($NmeRtiStorageAccountName) {
            $RequiredDnsZones += $TableDnsZoneName
            $TableDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name $TableDnsZoneName -ErrorAction Stop
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
    if ($NmeRtiStorageAccountName) {
        $TableDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name $TableDnsZoneName -ErrorAction SilentlyContinue
    }
    $AppServiceDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name $AppServiceDnsZoneName -ErrorAction SilentlyContinue
}

#### helper functions ####
function GetEntAppName {
    # check if mggraph module installed
    if (!(Get-Module -ListAvailable -Name Microsoft.Graph.Applications)) {
        Write-Verbose "Installing Microsoft.Graph.Applications module to retrieve app name"
        # -MinimumVersion pinned to 2.0.0: that's the first version whose Connect-MgGraph
        # parameter sets support -Identity, which the managed-identity branch below needs.
        # -Scope CurrentUser avoids failing in a sandbox that can't elevate to AllUsers.
        Install-Module -Name Microsoft.Graph.Applications -Repository PSGallery -Force -Scope CurrentUser -AllowClobber -MinimumVersion '2.0.0'
    }

    $ctx = Get-AzContext
    if (!$ctx) {
        throw "GetEntAppName: Get-AzContext returned nothing - no Azure context is active to resolve the running identity's display name."
    }

    $AppId = $ctx.Account.Id
    $TenantId = $ctx.Tenant.Id
    # A certificate-based service principal login (NME's default connection mode) records its
    # thumbprint in ExtendedProperties. $ctx.Account.CertificateThumbprint is not a real property
    # on PSAzureRmAccount - reading it always returned $null, which is why auth silently failed.
    $Thumbprint = $null
    if ($ctx.Account.ExtendedProperties) {
        $Thumbprint = $ctx.Account.ExtendedProperties['CertificateThumbprint']
    }

    # Connect-MgGraph needs to be told which cloud it's targeting or it silently fails to
    # authenticate in sovereign clouds. This script supports US Gov elsewhere (see the
    # azurewebsites.us branching), so map the Az environment name to a Graph environment.
    $GraphEnvironment = switch ($ctx.Environment.Name) {
        'AzureUSGovernment' { 'USGov' }
        'AzureChinaCloud'   { 'China' }
        'AzureGermanCloud'  { 'Germany' }
        default             { 'Global' }
    }

    if ($Thumbprint) {
        # NME's default connection mode: certificate-based service principal.
        Connect-MgGraph -TenantId $TenantId -ClientId $AppId -CertificateThumbprint $Thumbprint -Environment $GraphEnvironment -NoWelcome
    }
    elseif ($ctx.Account.Type -eq 'ManagedService') {
        # NME's MANAGED_IDENTITY_ connection mode. NME's _Connect-AzAccount always passes
        # -AccountId, so try the user-assigned form first; fall back to the system-assigned
        # form (no -ClientId) because Connect-MgGraph rejects -ClientId for system-assigned
        # identities.
        try {
            Connect-MgGraph -Identity -ClientId $AppId -Environment $GraphEnvironment -NoWelcome
        }
        catch {
            Connect-MgGraph -Identity -Environment $GraphEnvironment -NoWelcome
        }
    }
    else {
        # Federated-credentials connection mode (or anything unrecognised) leaves no reusable
        # secret or certificate in the context - there is no credential this function can use
        # to authenticate to Microsoft Graph. Throw before the try/catch below so this message
        # reaches the caller unwrapped instead of being re-wrapped by the generic catch.
        throw "GetEntAppName: the Azure connection in use (Account.Type = '$($ctx.Account.Type)') leaves no credential this script can reuse to authenticate to Microsoft Graph, so the SQL Entra admin display name cannot be looked up automatically. Set the SQL server's Entra admin to a named user or group in the Azure Portal and re-run."
    }

    try {
        # A service principal (not an application object) exists in the tenant for BOTH an
        # application registration and a managed identity - an application object exists only
        # for the former. The previous app-object lookup by app id would return nothing for a
        # managed identity, which is why it silently broke that auth mode.
        $ServicePrincipal = Get-MgServicePrincipal -Filter "appId eq '$AppId'" -ErrorAction Stop
        if (!$ServicePrincipal) {
            throw "No service principal found in the tenant for appId '$AppId'."
        }
        # .Count on a single (non-collection) object is unreliable in PowerShell; wrap in @() first.
        $ServicePrincipal = @($ServicePrincipal)[0]
        return $ServicePrincipal.DisplayName
    }
    catch {
        # This recovery path exists specifically so the caller's "Disable in Azure Portal"
        # fallback doesn't mask the real cause - surface it plus the actionable permission fix.
        throw "GetEntAppName: failed to resolve the running identity's display name via Microsoft Graph: $($_.Exception.Message). The identity running this scripted action needs Microsoft Graph permission to read service principals (Application.Read.All or Directory.Read.All) for this recovery path to work."
    }
    finally {
        if (Get-MgContext) {
            try {
                Disconnect-MgGraph | Out-Null
            }
            catch {
                Write-Verbose "GetEntAppName: failed to disconnect from Microsoft Graph cleanly: $($_.Exception.Message)"
            }
        }
    }
}

function Disable-NmeSqlPublicAccess {
    # All three NME SQL servers (primary, Real Time Insights, Intune Insights) get the same
    # treatment. The primary server used to call Set-AzSqlServer bare: with
    # $ErrorActionPreference = 'Stop' that aborted the whole script if it hit the Entra-admin
    # condition the other two already handled - and it runs after the key vault has been locked
    # down, which is the worst point to abort.
    param(
        [Parameter(Mandatory=$true)][string]$ServerName,
        [Parameter(Mandatory=$true)][string]$ResourceGroupName,
        [Parameter(Mandatory=$true)][string]$PrivateEndpointSubnetId,
        # Used in output messages, e.g. "SQL", "RTI SQL", "Intune Insights SQL".
        [Parameter(Mandatory=$true)][string]$DisplayName
    )
    $SqlServer = Get-AzSqlServer -ResourceGroupName $ResourceGroupName -ServerName $ServerName
    if ($SqlServer.PublicNetworkAccess -eq 'Disabled') {
        Write-Output "$DisplayName public access already disabled"
        return
    }
    Write-Output "Disabling $DisplayName public access"
    $ServerRules = Get-AzSqlServerVirtualNetworkRule -ServerName $ServerName -ResourceGroupName $ResourceGroupName
    if ($ServerRules.VirtualNetworkSubnetId -notcontains $PrivateEndpointSubnetId) {
        New-AzSqlServerVirtualNetworkRule -VirtualNetworkRuleName 'Allow private endpoint subnet' -VirtualNetworkSubnetId $PrivateEndpointSubnetId -ServerName $ServerName -ResourceGroupName $ResourceGroupName | Out-Null
    }
    # An equivalent 'Allow app service subnet' rule was commented out at all three original call
    # sites; left out here deliberately. Traffic arriving over a private endpoint is not evaluated
    # against VNet rules at all, and once PublicNetworkAccess is Disabled these rules are inert.
    if ($SqlServer.PublicNetworkAccess -ne 'Enabled') {
        return
    }
    try {
        Set-AzSqlServer -ServerName $ServerName -ResourceGroupName $ResourceGroupName -PublicNetworkAccess Disabled | Out-Null
    }
    catch {
        try {
            if ($SqlServer.Administrators.Sid.guid -eq $SqlServer.Administrators.login) {
                # Workaround for an app id (rather than a named principal) being set as the Entra
                # admin: resolve that identity's display name and set it as the admin, then retry.
                $AppName = GetEntAppName
                Set-AzSqlServerActiveDirectoryAdministrator -ResourceGroupName $ResourceGroupName -ServerName $ServerName -DisplayName $AppName
                Set-AzSqlServer -ServerName $ServerName -ResourceGroupName $ResourceGroupName -PublicNetworkAccess Disabled | Out-Null
            }
            else {
                Write-Output "Disabling $DisplayName public network access failed. Disable in Azure Portal"
                Write-Output $_
                Write-Warning "Disabling $DisplayName public network access failed. Disable in Azure Portal"
            }
        }
        catch {
            Write-Output "Disabling $DisplayName public network access failed. Disable in Azure Portal"
            Write-Output $_
            Write-Warning "Disabling $DisplayName public network access failed. Disable in Azure Portal"
        }
    }
}

function Set-NmeSubnetConfig {
    # Set-AzVirtualNetworkSubnetConfig replaces the whole subnet definition with only the parameters
    # supplied, so any NSG, route table or delegation on the subnet has to be passed back in or it is
    # silently removed.
    param(
        [Parameter(Mandatory=$true)]$VirtualNetwork,
        [Parameter(Mandatory=$true)][string]$SubnetName,
        [string[]]$ServiceEndpoint,
        [Parameter(Mandatory=$true)][string]$PrivateEndpointNetworkPoliciesFlag
    )
    $Subnet = Get-AzVirtualNetworkSubnetConfig -Name $SubnetName -VirtualNetwork $VirtualNetwork
    $Params = @{
        Name                               = $SubnetName
        AddressPrefix                      = $Subnet.AddressPrefix
        PrivateEndpointNetworkPoliciesFlag = $PrivateEndpointNetworkPoliciesFlag
    }
    if ($ServiceEndpoint)                { $Params['ServiceEndpoint']        = $ServiceEndpoint }
    if ($Subnet.NetworkSecurityGroup.Id) { $Params['NetworkSecurityGroupId'] = $Subnet.NetworkSecurityGroup.Id }
    if ($Subnet.RouteTable.Id)           { $Params['RouteTableId']           = $Subnet.RouteTable.Id }
    if ($Subnet.Delegations)             { $Params['Delegation']             = $Subnet.Delegations }
    $VirtualNetwork | Set-AzVirtualNetworkSubnetConfig @Params | Set-AzVirtualNetwork
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

# Private endpoints must be created in the same region as the VNet holding their subnet, which is
# not necessarily the region NME is deployed in when an existing VNet is supplied.
$VnetLocation = $VNet.Location
if ($VnetLocation -ne $NmeRegion) {
    Write-Warning "The VNet '$PrivateLinkVnetName' is in region '$VnetLocation' but Nerdio Manager is deployed in '$NmeRegion'. Private endpoints will be created in '$VnetLocation' to match the VNet, but App Service regional VNet integration requires the VNet to be in the same region as the app service plan, so the VNet integration steps later in this script are likely to fail. Use a VNet in the '$NmeRegion' region."
}
# Capture the VNet's resource group so later lookups are unambiguous - an existing VNet may live in
# a different resource group than NME, and fetching by name alone can match VNets in other groups.
$VnetRg = $VNet.ResourceGroupName

# Resolved once here, after $VNet exists: the "exclude the private endpoint VNet itself" filter
# below needs $vnet.id, and this used to run before $VNet was assigned, so the filter silently
# excluded nothing. If this VNet is also linked in NME it would then land in the peer list and
# the DNS zone link loops would try to link it to a zone it was already linked to.
if ($PeerVnetIds -eq 'All') {
    $VnetIds = Get-AzVirtualNetwork |
        Where-Object { $null -ne $_.Tag } |
        Where-Object { $_.Tag["$Prefix`_OBJECT_TYPE"] -eq 'LINKED_NETWORK' } |
        Where-Object { $_.Id -ne $VNet.Id } |
        Select-Object -ExpandProperty Id
}
else {
    $VnetIds = if ($PeerVnetIds) { $PeerVnetIds -split ',' } else { @() }
}

function Get-NmePeerVnetLinkName {
    # Private DNS zone link names must be stable across runs: naming them by an index that restarts
    # at 0 each run meant a peer VNet added later reused an existing name that pointed at a different
    # VNet, and Azure rejected it. Deriving the name from the peer VNet makes it idempotent.
    param(
        [Parameter(Mandatory=$true)][string]$BaseName,
        [Parameter(Mandatory=$true)][string]$VnetResourceId
    )
    $PeerVnetName = $VnetResourceId.Split('/')[-1]
    $LinkName = "$BaseName-$PeerVnetName"
    # Azure caps private DNS zone virtual network link names at 80 characters. If the composed name
    # is too long, truncate and append a short hash of the full resource id so two long VNet names
    # that share a prefix still produce distinct names.
    if ($LinkName.Length -gt 80) {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $Suffix = ([System.BitConverter]::ToString(
                $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($VnetResourceId))
            ).Replace('-', '')).Substring(0, 8)
        }
        finally { $sha256.Dispose() }
        $LinkName = $LinkName.Substring(0, 80 - ($Suffix.Length + 1)) + "-$Suffix"
    }
    return $LinkName
}

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
            Write-Output "Private DNS Zone for SQL already linked to vnet"
        }
        else {
            Write-Output "Linking Private DNS Zone for SQL to vnet"
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
            Write-Output "Private DNS Zone for Storage already linked to vnet"
        }
        else {
            Write-Output "Linking Private DNS Zone for Storage to vnet"
            $StorageZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $StorageDnsZoneName -Name $BlobZoneLinkName -VirtualNetworkId $vnet.Id
        }
    }
    else {
        Write-Output "Creating Private DNS Zones and VNet link for Storage"
        $StorageDnsZone = New-AzPrivateDnsZone -ResourceGroupName $NmeRg -Name $StorageDnsZoneName
        $StorageZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NmeRg -ZoneName $StorageDnsZoneName -Name $BlobZoneLinkName -VirtualNetworkId $vnet.Id
    }

    # Real Time Insights storage account uses the table storage API, so it needs its own private DNS zone
    if ($NmeRtiStorageAccountName) {
        if ($TableDnsZone) {
            Write-Output "Found Private DNS Zone for Table Storage"
            # check for linked zone
            $TableZoneLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $TableDnsZoneName -ErrorAction SilentlyContinue
            if ($TableZoneLink.VirtualNetworkId -contains $vnet.id) {
                Write-Output "Private DNS Zone for Table Storage already linked to vnet"
            }
            else {
                Write-Output "Linking Private DNS Zone for Table Storage to vnet"
                $TableZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $TableDnsZoneName -Name $RtiTableStoragePrivateDnsZoneLinkName -VirtualNetworkId $vnet.Id
            }
        }
        else {
            Write-Output "Creating Private DNS Zones and VNet link for Table Storage"
            $TableDnsZone = New-AzPrivateDnsZone -ResourceGroupName $NmeRg -Name $TableDnsZoneName
            $TableZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NmeRg -ZoneName $TableDnsZoneName -Name $RtiTableStoragePrivateDnsZoneLinkName -VirtualNetworkId $vnet.Id
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

    if ($PeerVnetIds) {
        $BlobStoragePrivateDnsZoneLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $StorageDnsZoneName -ErrorAction SilentlyContinue
        $MissingLinks = $VnetIds | Where-Object { $BlobStoragePrivateDnsZoneLink.VirtualNetworkId -notcontains $_ }
        if ($MissingLinks) {
            Write-Output "Linking Private DNS Zone for Blob Storage to peer vnets"
            foreach ($vnetId in $MissingLinks) {
                $BlobStoragePrivateDnsZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $StorageDnsZoneName -Name (Get-NmePeerVnetLinkName -BaseName $BlobStoragePrivateDnsZoneLinkName -VnetResourceId $vnetId) -VirtualNetworkId $vnetId
            }
        }
        if ($MakeAppServicePrivate -eq 'true'){
            $AppServicePrviateDnsZoneLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $AppServiceDnsZoneName -ErrorAction SilentlyContinue
            $AppServiceMissingLinks = $VnetIds | Where-Object { $AppServicePrviateDnsZoneLink.VirtualNetworkId -notcontains $_ }
            if ($AppServiceMissingLinks) {
                Write-Output "Linking Private DNS Zone for App Service to peer vnets"
                foreach ($vnetId in $AppServiceMissingLinks) {
                    $AppServicePrviateDnsZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $AppServiceDnsZoneName -Name (Get-NmePeerVnetLinkName -BaseName $AppServiceZoneLinkName -VnetResourceId $vnetId) -VirtualNetworkId $vnetId
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
$VNet = Get-AzVirtualNetwork -Name $PrivateLinkVnetName -ResourceGroupName $VnetRg -ErrorAction SilentlyContinue
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
    $KvPrivateEndpoint = New-AzPrivateEndpoint -Name "$KvPrivateEndpointName" -ResourceGroupName $NmeRg -Location $VnetLocation -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $KvServiceConnection
}


# check if keyvault dns zone group created
if ($SkipDNS -ne 'True') {
    $KvDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $KvPrivateEndpoint.Name -ErrorAction SilentlyContinue
    if ($KvDnsZoneGroup) {
        Write-Output "Found Key Vault DNS zone group"
    } else {
        Write-Output "Configuring keyvault DNS zone group"
        $Config = New-AzPrivateDnsZoneConfig -Name $KeyVaultDnsZoneName  -PrivateDnsZoneId $KeyVaultDnsZone.ResourceId
        # Use the discovered endpoint's actual .Name (not this script's naming convention): a pre-existing private
        # endpoint is matched by PrivateLinkServiceId, so its name may not follow the convention, and the DNS zone
        # group must be attached to the endpoint that actually exists.
        $KvDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $KvPrivateEndpoint.Name -Name "$KvDnsZoneGroupName" -PrivateDnsZoneConfig $config
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
        $CclKvPrivateEndpoint = New-AzPrivateEndpoint -Name "$CclKvPrivateEndpointName" -ResourceGroupName $NmeRg -Location $VnetLocation -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $CclKvServiceConnection
    }
    # check if ccl keyvault dns zone group created
    if ($SkipDNS -ne 'True') {
        $CclKvDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $CclKvPrivateEndpoint.Name -ErrorAction SilentlyContinue
        if ($CclKvDnsZoneGroup) {
            Write-Output "Found CCL Key Vault DNS zone group"
        } else {
            Write-Output "Configuring CCL keyvault DNS zone group"
            $Config = New-AzPrivateDnsZoneConfig -Name $KeyVaultDnsZoneName  -PrivateDnsZoneId $KeyVaultDnsZone.ResourceId
            $CclKvDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $CclKvPrivateEndpoint.Name -Name "$CclKvDnsZoneGroupName" -PrivateDnsZoneConfig $config
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
        $IiKvPrivateEndpoint = New-AzPrivateEndpoint -Name "$IiKvPrivateEndpointName" -ResourceGroupName $NmeRg -Location $VnetLocation -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $IiKvServiceConnection
    }
    # check if intune insights keyvault dns zone group created
    if ($SkipDNS -ne 'True') {
        $IiKvDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $IiKvPrivateEndpoint.Name -ErrorAction SilentlyContinue
        if ($IiKvDnsZoneGroup) {
            Write-Output "Found Intune Insights Key Vault DNS zone group"
        } else {
            Write-Output "Configuring Intune Insights keyvault DNS zone group"
            $Config = New-AzPrivateDnsZoneConfig -Name $KeyVaultDnsZoneName  -PrivateDnsZoneId $KeyVaultDnsZone.ResourceId
            $IiKvDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $IiKvPrivateEndpoint.Name -Name "$IiKvDnsZoneGroupName" -PrivateDnsZoneConfig $Config
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
    $SqlPrivateEndpoint = New-AzPrivateEndpoint -Name "$SqlPrivateEndpointName" -ResourceGroupName $NmeRg -Location $VnetLocation -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $SqlServiceConnection 
}

# check if sql dns zone group created
if ($SkipDNS -ne 'True') {
    $SqlDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $SqlPrivateEndpoint.Name -ErrorAction SilentlyContinue
    if ($SqlDnsZoneGroup) {
        Write-Output "Found SQL DNS zone group"
    } else {
        Write-Output "Configuring sql DNS zone group"
        $Config = New-AzPrivateDnsZoneConfig -Name $SqlDnsZoneName -PrivateDnsZoneId $SqlDnsZone.ResourceId
        $SqlDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $SqlPrivateEndpoint.Name -Name "$SqlDnsZoneGroupName" -PrivateDnsZoneConfig $config
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
        $IiSqlPrivateEndpoint = New-AzPrivateEndpoint -Name "$IiSqlPrivateEndpointName" -ResourceGroupName $NmeRg -Location $VnetLocation -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $IiSqlServiceConnection 
    }
    # check if intune insights sql dns zone group created
    if ($SkipDNS -ne 'True') {
        $IiSqlDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $IiSqlPrivateEndpoint.Name -ErrorAction SilentlyContinue
        if ($IiSqlDnsZoneGroup) {
            Write-Output "Found Intune Insights SQL DNS zone group"
        } else {
            Write-Output "Configuring Intune Insights sql DNS zone group"
            $Config = New-AzPrivateDnsZoneConfig -Name $SqlDnsZoneName -PrivateDnsZoneId $SqlDnsZone.ResourceId
            $IiSqlDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $IiSqlPrivateEndpoint.Name -Name "$IiSqlDnsZoneGroupName" -PrivateDnsZoneConfig $config
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
    $AutomationPrivateEndpoint = New-AzPrivateEndpoint -Name "$AutomationPrivateEndpointName" -ResourceGroupName $NmeRg -Location $VnetLocation -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $AutomationServiceConnection 

}
# check if automation account dns zone group created
if ($SkipDNS -ne 'True') {
    $AutomationDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $AutomationPrivateEndpoint.Name -ErrorAction SilentlyContinue
    if ($AutomationDnsZoneGroup) {
        Write-Output "Found Automation DNS zone group"
    } else {
        Write-Output "Configuring automation DNS zone group"
        $Config = New-AzPrivateDnsZoneConfig -Name $AutomationDnsZoneName -PrivateDnsZoneId $AutomationDnsZone.ResourceId
        $AutomationDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $AutomationPrivateEndpoint.Name -Name "$AutomationDnsZoneGroupName" -PrivateDnsZoneConfig $config
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
        $ScriptedActionsPrivateEndpoint = New-AzPrivateEndpoint -Name $ScriptedActionsPrivateEndpointName -ResourceGroupName $NmeRg -Location $VnetLocation -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $ScriptedActionsServiceConnection 
    }
    # check if scripted action automation account dns zone group created
    if ($SkipDNS -ne 'True') {
        $ScriptedActionsDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $ScriptedActionsPrivateEndpoint.Name -ErrorAction SilentlyContinue
        if ($ScriptedActionsDnsZoneGroup) {
            Write-Output "Found scripted actions DNS zone group"
        } else {
            Write-Output "Configuring scripted actions DNS zone group"
            $Config = New-AzPrivateDnsZoneConfig -Name $AutomationDnsZoneName -PrivateDnsZoneId $AutomationDnsZone.ResourceId
            $ScriptedActionsDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $ScriptedActionsPrivateEndpoint.Name -Name "$ScriptedActionsDnsZoneGroupName" -PrivateDnsZoneConfig $config
        }
    } else {
        Write-Output "Skipping scripted actions DNS zone group configuration (SkipDNS enabled)"
    }

    if ($MakeSaStoragePrivate -eq 'True') {
        # Get scripted actions storage account (resolved in Set-NmeVars via tag, then name pattern, then the NMW_RESOURCE fallback tag)
        $ScriptedActionsStorageAccount = Get-AzStorageAccount -ResourceGroupName $NmeRg -Name $NmeScriptedActionsStorageAccountName -ErrorAction SilentlyContinue
        # throw error if no scripted actions storage account found
        if (-not $ScriptedActionsStorageAccount) {
            throw "No scripted actions storage account found in resource group $NmeRg. Please add the tag '$NmeResourceTagName' with value 'CUSTOM_SCRIPTS_STORAGE_ACCOUNT' to the scripted actions storage account used by Nerdio Manager and rerun this script."
        }
        # check if scripted action storage account private endpoint is created
        $ScriptedActionsStoragePrivateEndpoint = $ExistingPrivateEndpoints | Where-Object { $_.PrivateLinkServiceConnections.PrivateLinkServiceId -eq $ScriptedActionsStorageAccount.Id }
        if ($ScriptedActionsStoragePrivateEndpoint) {
            Write-Output "Found scripted actions storage private endpoint"
        } 
        else {
            Write-Output "Configuring scripted actions storage service connection and private endpoint"
            $ScriptedActionsStorageServiceConnection = New-AzPrivateLinkServiceConnection -Name $SaStorageServiceConnectionName -PrivateLinkServiceId $ScriptedActionsStorageAccount.Id -GroupId blob 
            $ScriptedActionsStoragePrivateEndpoint = New-AzPrivateEndpoint -Name "$ScriptedActionsStoragePrivateEndpointName" -ResourceGroupName $NmeRg -Location $VnetLocation -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $ScriptedActionsStorageServiceConnection 
        }
        # check if scripted action storage account dns zone group created
        if ($SkipDNS -ne 'True') {
            $ScriptedActionsStorageDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $ScriptedActionsStoragePrivateEndpoint.Name -ErrorAction SilentlyContinue
            if ($ScriptedActionsStorageDnsZoneGroup) {
                Write-Output "Found scripted actions storage DNS zone group"
            } else {
                Write-Output "Configuring scripted actions storage DNS zone group"
                $Config = New-AzPrivateDnsZoneConfig -Name $StorageDnsZoneName -PrivateDnsZoneId $StorageDnsZone.ResourceId
                $ScriptedActionsStorageDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $ScriptedActionsStoragePrivateEndpoint.Name -Name $SaStoragePrivateDnsZoneGroupName -PrivateDnsZoneConfig $config
            }
        } else {
            Write-Output "Skipping scripted actions storage DNS zone group configuration (SkipDNS enabled)"
        }

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
        $CclStoragePrivateEndpoint = New-AzPrivateEndpoint -Name "$CclStoragePrivateEndpointName" -ResourceGroupName $NmeRg -Location $VnetLocation -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $CclStorageServiceConnection 
    }
    # check if ccl storage account dns zone group created
    if ($SkipDNS -ne 'True') {
        $CclStorageDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $CclStoragePrivateEndpoint.Name -ErrorAction SilentlyContinue
        if ($CclStorageDnsZoneGroup) {
            Write-Output "Found CCL storage DNS zone group"
        } else {
            Write-Output "Configuring CCL storage DNS zone group"
            $Config = New-AzPrivateDnsZoneConfig -Name $StorageDnsZoneName -PrivateDnsZoneId $StorageDnsZone.ResourceId
            $CclStorageDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $CclStoragePrivateEndpoint.Name -Name $CclStoragePrivateDnsZoneGroupName -PrivateDnsZoneConfig $config
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
        $DpsStoragePrivateEndpoint = New-AzPrivateEndpoint -Name "$DpsStoragePrivateEndpointName" -ResourceGroupName $NmeRg -Location $VnetLocation -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $DpsStorageServiceConnection 
    }
    # check if dps storage account dns zone group created
    if ($SkipDNS -ne 'True') {
        $DpsStorageDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $DpsStoragePrivateEndpoint.Name -ErrorAction SilentlyContinue
        if ($DpsStorageDnsZoneGroup) {
            Write-Output "Found DPS storage DNS zone group"
        } else {
            Write-Output "Configuring DPS storage DNS zone group"
            $Config = New-AzPrivateDnsZoneConfig -Name $StorageDnsZoneName -PrivateDnsZoneId $StorageDnsZone.ResourceId
            $DpsStorageDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $DpsStoragePrivateEndpoint.Name -Name $DpsStoragePrivateDnsZoneGroupName -PrivateDnsZoneConfig $config
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
    $AppServicePrivateEndpoint = New-AzPrivateEndpoint -Name "$AppServicePrivateEndpointName" -ResourceGroupName $NmeRg -Location $VnetLocation -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $AppServiceServiceConnection 
}
# check if app service dns zone group created
if ($SkipDNS -ne 'True') {
    $AppServiceDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $AppServicePrivateEndpoint.Name -ErrorAction SilentlyContinue
    if ($AppServiceDnsZoneGroup) {
        Write-Output "Found App Service DNS zone group"
    } else {
        Write-Output "Configuring app service DNS zone group"
        $Config = New-AzPrivateDnsZoneConfig -Name $AppServiceDnsZoneName -PrivateDnsZoneId $AppServiceDnsZone.ResourceId
        $AppServiceDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $AppServicePrivateEndpoint.Name -Name $AppServicePrivateDnsZoneGroupName -PrivateDnsZoneConfig $config
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
        $CclAppServicePrivateEndpoint = New-AzPrivateEndpoint -Name "$CclAppServicePrivateEndpointName" -ResourceGroupName $NmeRg -Location $VnetLocation -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $CclAppServiceServiceConnection 
    }
    # check if ccl app service dns zone group created
    if ($SkipDNS -ne 'True') {
        $CclAppServiceDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $CclAppServicePrivateEndpoint.Name -ErrorAction SilentlyContinue
        if ($CclAppServiceDnsZoneGroup) {
            Write-Output "Found CCL App Service DNS zone group"
        } else {
            Write-Output "Configuring CCL app service DNS zone group"
            $Config = New-AzPrivateDnsZoneConfig -Name $AppServiceDnsZoneName -PrivateDnsZoneId $AppServiceDnsZone.ResourceId
            $CclAppServiceDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $CclAppServicePrivateEndpoint.Name -Name $CclAppServiceDnsZoneGroupName -PrivateDnsZoneConfig $config
        }
    } else {
        Write-Output "Skipping CCL App Service DNS zone group configuration (SkipDNS enabled)"
    }
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
        $IiAppServicePrivateEndpoint = New-AzPrivateEndpoint -Name "$IiAppServicePrivateEndpointName" -ResourceGroupName $NmeRg -Location $VnetLocation -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $IiAppServiceServiceConnection 
    }
    # check if intune insights app service dns zone group created
    if ($SkipDNS -ne 'True') {
        $IiAppServiceDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $IiAppServicePrivateEndpoint.Name -ErrorAction SilentlyContinue
        if ($IiAppServiceDnsZoneGroup) {
            Write-Output "Found Intune Insights App Service DNS zone group"
        } else {
            Write-Output "Configuring Intune Insights app service DNS zone group"
            $Config = New-AzPrivateDnsZoneConfig -Name $AppServiceDnsZoneName -PrivateDnsZoneId $AppServiceDnsZone.ResourceId
            $IiAppServiceDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $IiAppServicePrivateEndpoint.Name -Name $IiAppServiceDnsZoneGroupName -PrivateDnsZoneConfig $config
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
        $RtiAppServicePrivateEndpoint = New-AzPrivateEndpoint -Name "$RtiAppServicePrivateEndpointName" -ResourceGroupName $NmeRg -Location $VnetLocation -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $RtiAppServiceServiceConnection 
    }
    # check if rti app service dns zone group created
    if ($SkipDNS -ne 'True') {
        $RtiAppServiceDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $RtiAppServicePrivateEndpoint.Name -ErrorAction SilentlyContinue
        if ($RtiAppServiceDnsZoneGroup) {
            Write-Output "Found RTI App Service DNS zone group"
        } else {
            Write-Output "Configuring RTI app service DNS zone group"
            $Config = New-AzPrivateDnsZoneConfig -Name $AppServiceDnsZoneName -PrivateDnsZoneId $AppServiceDnsZone.ResourceId
            $RtiAppServiceDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $RtiAppServicePrivateEndpoint.Name -Name $RtiAppServiceDnsZoneGroupName -PrivateDnsZoneConfig $config
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
        $RtiSqlPrivateEndpoint = New-AzPrivateEndpoint -Name "$RtiSqlPrivateEndpointName" -ResourceGroupName $NmeRg -Location $VnetLocation -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $RtiSqlServiceConnection 
    }
    # check if rti sql dns zone group created
    if ($SkipDNS -ne 'True') {
        $RtiSqlDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $RtiSqlPrivateEndpoint.Name -ErrorAction SilentlyContinue
        if ($RtiSqlDnsZoneGroup) {
            Write-Output "Found RTI SQL DNS zone group"
        } else {
            Write-Output "Configuring RTI sql DNS zone group"
            $Config = New-AzPrivateDnsZoneConfig -Name $SqlDnsZoneName -PrivateDnsZoneId $SqlDnsZone.ResourceId
            $RtiSqlDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $RtiSqlPrivateEndpoint.Name -Name $RtiSqlDnsZoneGroupName -PrivateDnsZoneConfig $config
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
        # Earlier versions of this script created this endpoint with the 'blob' sub-resource. RTI uses the
        # table storage API, so a blob-only endpoint leaves table traffic resolving to the public endpoint.
        # A private endpoint's sub-resource (groupId) cannot be changed in place - it has to be recreated.
        $RtiStorageGroupIds = $RtiStoragePrivateEndpoint.PrivateLinkServiceConnections.GroupIds
        if ($RtiStorageGroupIds -notcontains 'table') {
            Write-Warning "The existing RTI storage private endpoint '$($RtiStoragePrivateEndpoint.Name)' uses the '$($RtiStorageGroupIds -join ',')' sub-resource, but Real Time Insights requires the 'table' sub-resource. Table storage traffic will continue to use the public endpoint. A private endpoint's sub-resource cannot be changed in place: delete the private endpoint '$($RtiStoragePrivateEndpoint.Name)' in the Azure Portal and re-run this script to have it recreated correctly."
        }
    }
    else {
        Write-Output "Configuring RTI storage service connection and private endpoint"
        # RTI storage account uses the table storage API only
        $RtiStorageServiceConnection = New-AzPrivateLinkServiceConnection -Name $RtiStorageServiceConnectionName -PrivateLinkServiceId $NmeRtiStorageAccount.Id -GroupId table
        $RtiStoragePrivateEndpoint = New-AzPrivateEndpoint -Name "$RtiStoragePrivateEndpointName" -ResourceGroupName $NmeRg -Location $VnetLocation -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $RtiStorageServiceConnection
    }
    # check if rti storage account dns zone group created
    if ($SkipDNS -ne 'True') {
        $RtiStorageDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $RtiStoragePrivateEndpoint.Name -ErrorAction SilentlyContinue
        if ($RtiStorageDnsZoneGroup) {
            Write-Output "Found RTI storage DNS zone group"
            # Earlier versions of this script linked this zone group to the blob zone instead of the table zone
            if ($RtiStorageDnsZoneGroup.PrivateDnsZoneConfigs.PrivateDnsZoneId -notcontains $TableDnsZone.ResourceId) {
                Write-Warning "The existing RTI storage DNS zone group '$($RtiStorageDnsZoneGroup.Name)' is not linked to the '$TableDnsZoneName' private DNS zone, so RTI table storage will not resolve to the private endpoint. Delete the private endpoint '$($RtiStoragePrivateEndpoint.Name)' in the Azure Portal and re-run this script to have the endpoint and its DNS zone group recreated correctly."
            }
        } else {
            Write-Output "Configuring RTI storage DNS zone group"
            $Config = New-AzPrivateDnsZoneConfig -Name $TableDnsZoneName -PrivateDnsZoneId $TableDnsZone.ResourceId
            $RtiStorageDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $RtiStoragePrivateEndpoint.Name -Name $RtiStorageDnsZoneGroupName -PrivateDnsZoneConfig $Config
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
        $RtiKvPrivateEndpoint = New-AzPrivateEndpoint -Name "$RtiKvPrivateEndpointName" -ResourceGroupName $NmeRg -Location $VnetLocation -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $RtiKvServiceConnection 
    }
    # check if rti key vault dns zone group created
    if ($SkipDNS -ne 'True') {
        $RtiKvDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $RtiKvPrivateEndpoint.Name -ErrorAction SilentlyContinue
        if ($RtiKvDnsZoneGroup) {
            Write-Output "Found RTI Key Vault DNS zone group"
        } else {
            Write-Output "Configuring RTI Key Vault DNS zone group"
            $Config = New-AzPrivateDnsZoneConfig -Name $KeyVaultDnsZoneName  -PrivateDnsZoneId $KeyVaultDnsZone.ResourceId
            $RtiKvDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $RtiKvPrivateEndpoint.Name -Name $RtiKvDnsZoneGroupName -PrivateDnsZoneConfig $Config
        }
    } else {
        Write-Output "Skipping RTI Key Vault DNS zone group configuration (SkipDNS enabled)"
    }
}

#endregion

# region create private link peering
if ($PeerVnetIds) {
    Write-Output "Peering vnets"
    $VNet = Get-AzVirtualNetwork -Name $PrivateLinkVnetName -ResourceGroupName $VnetRg
    foreach ($id in $VnetIds) {
        Write-Output "Peering with vnet $id"
        $VNet = Get-AzVirtualNetwork -Name $PrivateLinkVnetName -ResourceGroupName $VnetRg -ErrorAction SilentlyContinue 
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
$VNet = Get-AzVirtualNetwork -Name $PrivateLinkVnetName -ResourceGroupName $VnetRg 
$PrivateEndpointSubnet = Get-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -VirtualNetwork $VNet
$AppServiceSubnet = Get-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -VirtualNetwork $VNet 

$ServiceEndpoints = @('Microsoft.KeyVault', 'Microsoft.Sql', 'Microsoft.Web')
if ($MakeSaStoragePrivate -eq 'True') {
    $ServiceEndpoints += 'Microsoft.Storage'
}
# Union with what is already on the subnet so a previous run's service endpoints (for example
# Microsoft.Storage from a run with MakeSaStoragePrivate enabled) are not removed.
$ExistingServiceEndpoints = @(@($PrivateEndpointSubnet.ServiceEndpoints.Service) | Where-Object { $_ })
$ServiceEndpoints = @($ExistingServiceEndpoints + $ServiceEndpoints | Select-Object -Unique)

# Since $ServiceEndpoints is the union of what's required and what's already there, "needs updating"
# reduces to "the union contains something the subnet doesn't already have". Compare-Object is avoided
# deliberately here: it throws on an empty -ReferenceObject, which is the state of a subnet on a first run.
$MissingServiceEndpoints = @($ServiceEndpoints | Where-Object { $ExistingServiceEndpoints -notcontains $_ })
if ($MissingServiceEndpoints.Count) {
    Write-Output "Adding service endpoints"
    $VNet = Set-NmeSubnetConfig -VirtualNetwork $VNet -SubnetName $PrivateEndpointSubnetName -ServiceEndpoint $ServiceEndpoints -PrivateEndpointNetworkPoliciesFlag Disabled
}
else {
    Write-Output "Found service endpoints"
}
# enable network policy
$PrivateEndpointSubnet = Get-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -VirtualNetwork $VNet
if ($PrivateEndpointSubnet.PrivateEndpointNetworkPolicies -eq 'Enabled') {
    Write-Output "Network policies already enabled"
} else {
    Write-Output "Enabling network policies"
    try {
        $VNet = Set-NmeSubnetConfig -VirtualNetwork $VNet -SubnetName $PrivateEndpointSubnetName -ServiceEndpoint $ServiceEndpoints -PrivateEndpointNetworkPoliciesFlag Enabled
    }
    catch {
        # sometimes can't enable network policies on subnet with private endpoints, e.g. in gov cloud
        Write-Output "Enabling network policies failed, setting to disabled"
        $VNet = Set-NmeSubnetConfig -VirtualNetwork $VNet -SubnetName $PrivateEndpointSubnetName -ServiceEndpoint $ServiceEndpoints -PrivateEndpointNetworkPoliciesFlag Disabled
    }
}


$VNet = Get-AzVirtualNetwork -Name $PrivateLinkVnetName -ResourceGroupName $VnetRg 
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
    # publicNetworkAccess is deliberately not written here. VNet integration is an outbound
    # concern and says nothing about whether the app service should be reachable from the
    # internet; setting it to "Enabled" silently re-exposed an app service the customer had
    # locked down, either manually or on a previous run with MakeAppServicePrivate = true.
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

    # The Cost Calculator web app is always made private, regardless of MakeAppServicePrivate.
    # Nothing but the primary Nerdio Manager web app talks to it, and that traffic goes over the
    # private network once the private endpoint and VNet integration above are in place - so
    # there is no scenario in which it needs to be reachable from the internet. This runs after
    # VNet integration deliberately: locking it down first would have cut off public access while
    # the private path was still being built.
    $CclWebApp = Get-AzResource -Id $NmeCclWebApp.id
    if ($CclWebApp.Properties.publicNetworkAccess -eq 'Disabled') {
        Write-Output "CCL app service public access already disabled"
    }
    else {
        Write-Output "Disabling CCL app service public access"
        $CclWebApp.Properties.publicNetworkAccess = "Disabled"
        $CclWebApp | Set-AzResource -Force | Out-Null
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
# privateEndpointNetworkPolicies is deliberately NOT set on the app service subnet. That flag only
# governs whether NSGs and route tables are applied to *private endpoints* in a subnet, and this
# subnet is delegated to Microsoft.Web/serverFarms and holds no private endpoints - so the flag has
# no effect here. NSG and UDR support on a VNet integration subnet does not depend on it. This
# previously printed "Enabling network policies" and then did nothing, because the only statement in
# the branch was commented out.
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
Disable-NmeSqlPublicAccess -ServerName $NmeSqlServerName -ResourceGroupName $NmeRg -PrivateEndpointSubnetId $PrivateEndpointSubnet.id -DisplayName 'SQL'

if ($MakeSaStoragePrivate -eq 'True') {
    # check if deny rule for storage exists (resolved in Set-NmeVars via tag, then name pattern, then the NMW_RESOURCE fallback tag)
    $StorageAccount = Get-AzStorageAccount -ResourceGroupName $NmeRg -Name $NmeScriptedActionsStorageAccountName -ErrorAction SilentlyContinue
    if ($StorageAccount.PublicNetworkAccess -eq 'Disabled') {
        Write-Output "Storage public access is already disabled"
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
    Disable-NmeSqlPublicAccess -ServerName $NmeRtiSqlServerName -ResourceGroupName $NmeRg -PrivateEndpointSubnetId $PrivateEndpointSubnet.id -DisplayName 'RTI SQL'
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
    Disable-NmeSqlPublicAccess -ServerName $NmeIiSqlServerName -ResourceGroupName $NmeRg -PrivateEndpointSubnetId $PrivateEndpointSubnet.id -DisplayName 'Intune Insights SQL'
}


#endregion

# Public network access is only ever written when MakeAppServicePrivate explicitly asks for it.
# The previous else branch wrote "Enabled" whenever the parameter was anything other than 'True',
# which meant a customer who locked the app service down manually - or who ran this script once
# with MakeAppServicePrivate = true and re-ran it later to add a component without re-supplying
# the flag - had their app service quietly re-exposed to the internet. Re-enabling public access
# is a deliberate act and is left to the Azure Portal.
if ($MakeAppServicePrivate -eq 'True') {
    $webApp = Get-AzResource -Id $NmeWebApp.id
    Write-Output "Disabling NME app service public access"
    $webApp.Properties.publicNetworkAccess = "Disabled"
    $webApp | Set-AzResource -Force | Out-Null
}
else {
    Write-Output "MakeAppServicePrivate is not set to true - leaving NME app service public network access unchanged."
}

# restart the app service
Write-Output "Restarting app service"
$restart = Restart-AzWebApp -ResourceGroupName $NmeRg -Name $NmeWebApp.Name