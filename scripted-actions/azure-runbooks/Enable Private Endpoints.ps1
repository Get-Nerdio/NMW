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
    "DefaultValue": "nmw-private-vnet"
  },
  "VnetAddressRange": {
    "Description": "Address range for private endpoint vnet. Not used if vnet already exists.",
    "IsRequired": false,
    "DefaultValue": "10.250.250.0/23"
  },
  "PrivateEndpointSubnetName": {
    "Description": "Name of private endpoint subnet. If the subnet does not exist, it will be created.",
    "IsRequired": true,
    "DefaultValue": "nmw-privateendpoints-subnet"
  },
  "PrivateEndpointSubnetRange": {
    "Description": "Address range for private endpoint subnet. Not used if subnet already exists.",
    "IsRequired": false,
    "DefaultValue": "10.250.250.0/24"
  },
  "AppServiceSubnetName": {
    "Description": "App service subnet name. If the subnet does not exist, it will be created.",
    "IsRequired": true,
    "DefaultValue": "nmw-app-subnet"
  },
  "AppServiceSubnetRange": {
    "Description": "Address range for app service subnet. Not used if subnet already exists.",
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
    "Description": "Make the scripted actions storage account private. Will create a hybrid worker VM, if one does not already exist. This will result in increased cost for Nerdio Manager Azure resources. WARNING: The hybrid worker VM is not a PaaS service. As such, you will be responsible for patching the VM. The hybrid worker VM will be created with a random local admin password. This can be reset using Reset Password fuction in the Azure Portal. NOTE: After this script completes, you must update Nerdio Manager to use the new hybrid worker. (Settings->Nerdio Environment->Azure runbooks scripted actions. Click Enabled and select the new hybrid worker.)",
    "IsRequired": false,
    "DefaultValue": "false"
  },
  "PeerVnetIds": {
    "Description": "Optional. Values are 'All' or comma-separated list of Azure resource IDs of VNets to peer to private endpoint VNet. If 'All' then all VNets NME manages will be peered. The VNEts or their resource groups must be linked to Nerdio Manager in Settings->Azure environment. All VNets must be in the same subscription as Nerdio Manager. External VNets must be peered manually.",
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
    if (!$Key) {
        $ScriptedActionsStorageAccount = Get-AzStorageAccount -ResourceGroupName $NmeRg | Where-Object StorageAccountName -Match 'cssa'
        $key = $ScriptedActionsStorageAccount.Tags.GetEnumerator() | Where-Object { $_.Value -eq "CUSTOM_SCRIPTS_STORAGE_ACCOUNT" } | Select-Object -ExpandProperty Key
    }
    else {
        $key = 'NMW_OBJECT_TYPE'
    }
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
    $script:NmeDpsStorageAccountName = Get-AzStorageAccount -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue | Where-Object { $_.StorageAccountName -match "^dps" } | Select-Object -ExpandProperty StorageAccountName
    if ($script:NmeDpsStorageAccountName.count -ne 1) {
        Write-Error "Unable to find DPS storage account"
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
        throw "Unable to find NME App Insights. Az.ApplicationInsights module may need to be updated to greater than v2.0.0 in the NME scripted action automation account."
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
    Write-Verbose "Getting Nerdio Manager sql server"
    if ($key){
        $SqlServer = Get-AzSqlServer -ResourceGroupName $nmerg | ? ServerName -NotMatch '-secondary' | Where-Object {$_.tags[$key] -ne 'INTUNE_INSIGHTS_DEPLOYMENT_RESOURCE' -and $_.tags[$key] -ne 'EIDO_DEPLOYMENT_RESOURCE'}
    }
    else {
        $SqlServer = Get-AzSqlServer -ResourceGroupName $nmerg | ? ServerName -NotMatch '-secondary'
    }
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
$IiKvDnsZoneGroupName = "$Prefix-ii-kv-dnszonegroup"
$IiSqlDnsZoneGroupName = "$Prefix-ii-sql-dnszonegroup"
$IiAppServiceDnsZoneGroupName = "$Prefix-ii-appservice-dnszonegroup"

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
$IiKvServiceConnectionName = "$Prefix-ii-kv-serviceconnection"
$IiAppServiceServiceConnectionName = "$Prefix-ii-appservice-serviceconnection"
$IiSqlServiceConnectionName = "$Prefix-ii-sql-serviceconnection"

# web app subnet delegation
$WebAppSubnetDelegationName = "$Prefix-app-webapp-subnetdelegation"

# define Azure monitor private link service settings
$IngestionAccessMode = 'Open'
$QueryAccessMode = 'Open'

# define variables for hybrid worker
$HybridWorkerVMName = "$Prefix-hybridworker-vm"
$HybridWorkerVMSize = 'Standard_D2s_v3'
$HybridWorkerGroupName = "$Prefix-hybridworker-group"

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

if ($PeerVnetIds -eq 'All') {
    $VnetIds = Get-AzVirtualNetwork | ? {if ($_.tag){$True}}| Where-Object {$_.tag["$Prefix`_OBJECT_TYPE"] -eq 'LINKED_NETWORK'} -ErrorAction SilentlyContinue | Where-Object id -ne $vnet.id | Select-Object -ExpandProperty Id
}
else {
    $VnetIds = $PeerVnetIds -split ','
}
# set resource group for dns zones
if ($ExistingDNSZonesRG) {
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

#### main script ####

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
$KvDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $KvPrivateEndpoint.Name -ErrorAction SilentlyContinue
if ($KvDnsZoneGroup) {
    Write-Output "Found Key Vault DNS zone group"
} else {
    Write-Output "Configuring keyvault DNS zone group"
    $Config = New-AzPrivateDnsZoneConfig -Name $KeyVaultDnsZoneName  -PrivateDnsZoneId $KeyVaultDnsZone.ResourceId
    $KvDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$KvPrivateEndpointName" -Name "$KvDnsZoneGroupName" -PrivateDnsZoneConfig $config
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
    $CclKvDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $CclKvPrivateEndpoint.Name -ErrorAction SilentlyContinue
    if ($CclKvDnsZoneGroup) {
        Write-Output "Found CCL Key Vault DNS zone group"
    } else {
        Write-Output "Configuring CCL keyvault DNS zone group"
        $Config = New-AzPrivateDnsZoneConfig -Name $KeyVaultDnsZoneName  -PrivateDnsZoneId $KeyVaultDnsZone.ResourceId
        $CclKvDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$CclKvPrivateEndpointName" -Name "$CclKvDnsZoneGroupName" -PrivateDnsZoneConfig $config
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
    $IiKvDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $IiKvPrivateEndpoint.Name -ErrorAction SilentlyContinue
    if ($IiKvDnsZoneGroup) {
        Write-Output "Found Intune Insights Key Vault DNS zone group"
    } else {
        Write-Output "Configuring Intune Insights keyvault DNS zone group"
        $Config = New-AzPrivateDnsZoneConfig -Name $KeyVaultDnsZoneName  -PrivateDnsZoneId $KeyVaultDnsZone.ResourceId
        $IiKvDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$IiKvPrivateEndpointName" -Name "$IiKvDnsZoneGroupName" -PrivateDnsZoneConfig $Config
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
$SqlDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $SqlPrivateEndpoint.Name -ErrorAction SilentlyContinue
if ($SqlDnsZoneGroup) {
    Write-Output "Found SQL DNS zone group"
} else {
    Write-Output "Configuring sql DNS zone group"
    $Config = New-AzPrivateDnsZoneConfig -Name $SqlDnsZoneName -PrivateDnsZoneId $SqlDnsZone.ResourceId
    $SqlDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$SqlPrivateEndpointName" -Name "$SqlDnsZoneGroupName" -PrivateDnsZoneConfig $config
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
    $IiSqlDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $IiSqlPrivateEndpoint.Name -ErrorAction SilentlyContinue
    if ($IiSqlDnsZoneGroup) {
        Write-Output "Found Intune Insights SQL DNS zone group"
    } else {
        Write-Output "Configuring Intune Insights sql DNS zone group"
        $Config = New-AzPrivateDnsZoneConfig -Name $SqlDnsZoneName -PrivateDnsZoneId $SqlDnsZone.ResourceId
        $IiSqlDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$IiSqlPrivateEndpointName" -Name "$IiSqlDnsZoneGroupName" -PrivateDnsZoneConfig $config
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
$AutomationDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $AutomationPrivateEndpoint.Name -ErrorAction SilentlyContinue
if ($AutomationDnsZoneGroup) {
    Write-Output "Found Automation DNS zone group"
} else {
    Write-Output "Configuring automation DNS zone group"
    $Config = New-AzPrivateDnsZoneConfig -Name $AutomationDnsZoneName -PrivateDnsZoneId $AutomationDnsZone.ResourceId
    $AutomationDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$AutomationPrivateEndpointName" -Name "$AutomationDnsZoneGroupName" -PrivateDnsZoneConfig $config
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
    $ScriptedActionsDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $ScriptedActionsPrivateEndpoint.Name -ErrorAction SilentlyContinue
    if ($ScriptedActionsDnsZoneGroup) {
        Write-Output "Found scripted actions DNS zone group"
    } else {
        Write-Output "Configuring scripted actions DNS zone group"
        $Config = New-AzPrivateDnsZoneConfig -Name $AutomationDnsZoneName -PrivateDnsZoneId $AutomationDnsZone.ResourceId
        $ScriptedActionsDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $ScriptedActionsPrivateEndpointName -Name "$ScriptedActionsDnsZoneGroupName" -PrivateDnsZoneConfig $config
    }

    if ($MakeSaStoragePrivate -eq 'True') {
        # Get scripted actions storage account
        $ScriptedActionsStorageAccount = Get-AzStorageAccount -ResourceGroupName $NmeRg | Where-Object StorageAccountName -Match 'cssa'
        # throw error if no scripted actions storage account found
        if (-not $ScriptedActionsStorageAccount) {
            throw "No scripted actions storage account found in resource group $NmeRg"
        }
        # check if scripted action storage account private endpoint is created
        $ScriptedActionsStoragePrivateEndpoint = $ExistingPrivateEndpoints | Where-Object { $_.PrivateLinkServiceConnections.PrivateLinkServiceId -eq $ScriptedActionsStorageAccount.Id }
        if ($ScriptedActionsStoragePrivateEndpoint) {
            Write-Output "Found scripted actions storage private endpoint"
        } 
        else {
            Write-Output "Configuring scripted actions storage service connection and private endpoint"
            $ScriptedActionsStorageServiceConnection = New-AzPrivateLinkServiceConnection -Name $SaStorageServiceConnectionName -PrivateLinkServiceId $ScriptedActionsStorageAccount.Id -GroupId blob 
            $ScriptedActionsStoragePrivateEndpoint = New-AzPrivateEndpoint -Name "$ScriptedActionsStoragePrivateEndpointName" -ResourceGroupName $NmeRg -Location $NmeRegion -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $ScriptedActionsStorageServiceConnection 
        }
        # check if scripted action storage account dns zone group created
        $ScriptedActionsStorageDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $ScriptedActionsStoragePrivateEndpoint.Name -ErrorAction SilentlyContinue
        if ($ScriptedActionsStorageDnsZoneGroup) {
            Write-Output "Found scripted actions storage DNS zone group"
        } else {
            Write-Output "Configuring scripted actions storage DNS zone group"
            $Config = New-AzPrivateDnsZoneConfig -Name $StorageDnsZoneName -PrivateDnsZoneId $StorageDnsZone.ResourceId
            $ScriptedActionsStorageDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$ScriptedActionsStoragePrivateEndpointName" -Name $SaStoragePrivateDnsZoneGroupName -PrivateDnsZoneConfig $config
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
        $CclStoragePrivateEndpoint = New-AzPrivateEndpoint -Name "$CclStoragePrivateEndpointName" -ResourceGroupName $NmeRg -Location $NmeRegion -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $CclStorageServiceConnection 
    }
    # check if ccl storage account dns zone group created
    $CclStorageDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $CclStoragePrivateEndpoint.Name -ErrorAction SilentlyContinue
    if ($CclStorageDnsZoneGroup) {
        Write-Output "Found CCL storage DNS zone group"
    } else {
        Write-Output "Configuring CCL storage DNS zone group"
        $Config = New-AzPrivateDnsZoneConfig -Name $StorageDnsZoneName -PrivateDnsZoneId $StorageDnsZone.ResourceId
        $CclStorageDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$CclStoragePrivateEndpointName" -Name $CclStoragePrivateDnsZoneGroupName -PrivateDnsZoneConfig $config
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
    $DpsStorageDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $DpsStoragePrivateEndpoint.Name -ErrorAction SilentlyContinue
    if ($DpsStorageDnsZoneGroup) {
        Write-Output "Found DPS storage DNS zone group"
    } else {
        Write-Output "Configuring DPS storage DNS zone group"
        $Config = New-AzPrivateDnsZoneConfig -Name $StorageDnsZoneName -PrivateDnsZoneId $StorageDnsZone.ResourceId
        $DpsStorageDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$DpsStoragePrivateEndpointName" -Name $DpsStoragePrivateDnsZoneGroupName -PrivateDnsZoneConfig $config

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
$AppServiceDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $AppServicePrivateEndpoint.Name -ErrorAction SilentlyContinue
if ($AppServiceDnsZoneGroup) {
    Write-Output "Found App Service DNS zone group"
} else {
    Write-Output "Configuring app service DNS zone group"
    $Config = New-AzPrivateDnsZoneConfig -Name $AppServiceDnsZoneName -PrivateDnsZoneId $AppServiceDnsZone.ResourceId
    $AppServiceDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$AppServicePrivateEndpointName" -Name $AppServicePrivateDnsZoneGroupName -PrivateDnsZoneConfig $config
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
    $CclAppServiceDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $CclAppServicePrivateEndpoint.Name -ErrorAction SilentlyContinue
    if ($CclAppServiceDnsZoneGroup) {
        Write-Output "Found CCL App Service DNS zone group"
    } else {
        Write-Output "Configuring CCL app service DNS zone group"
        $Config = New-AzPrivateDnsZoneConfig -Name $AppServiceDnsZoneName -PrivateDnsZoneId $AppServiceDnsZone.ResourceId
        $CclAppServiceDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$CclAppServicePrivateEndpointName" -Name $AppServicePrivateDnsZoneGroupName -PrivateDnsZoneConfig $config
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
    $IiAppServiceDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $IiAppServicePrivateEndpoint.Name -ErrorAction SilentlyContinue
    if ($IiAppServiceDnsZoneGroup) {
        Write-Output "Found Intune Insights App Service DNS zone group"
    } else {
        Write-Output "Configuring Intune Insights app service DNS zone group"
        $Config = New-AzPrivateDnsZoneConfig -Name $AppServiceDnsZoneName -PrivateDnsZoneId $AppServiceDnsZone.ResourceId
        $IiAppServiceDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$IiAppServicePrivateEndpointName" -Name $IiAppServiceDnsZoneGroupName -PrivateDnsZoneConfig $config
    }
    # disable public network access for Intune Insights web app
    $IiWebAppResource = Get-AzResource -Id $IiWebApp.id
    $IiWebAppResource.Properties.publicNetworkAccess = "Disabled"
    $IiWebAppResource | Set-AzResource -Force | Out-Null
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
        Write-Output "Found Azure Monitor private link scope"
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
        Write-Output "Found Azure Monitor LAW scope"
    } 
    else {
        Write-Output "Creating Azure Monitor LAW scope"
        $LAWScope = New-AzInsightsPrivateLinkScopedResource -LinkedResourceId $NmeLogAnalyticsWorkspaceId -ResourceGroupName $NmeRg -ScopeName $AmplScopeName -Name $NmeLAWName
    }

    # Check if App Insights Scope exists
    $AppInsightsScope = Get-AzInsightsPrivateLinkScopedResource -ResourceGroupName $NmeRg -ScopeName $AmplScopeName -Name "$NmeAppInsightsName" -ErrorAction SilentlyContinue
    if ($AppInsightsScope) {
        Write-Output "Found Azure Monitor App Insights scope"
    } 
    else {
        Write-Output "Creating Azure Monitor App Insights scope"
        $AppInsights = Get-AzApplicationInsights -ResourceGroupName $NmeRg -Name "$NmeAppInsightsName"
        $AppInsightsScope = New-AzInsightsPrivateLinkScopedResource -LinkedResourceId $AppInsights.id -ResourceGroupName $NmeRg -ScopeName $AmplScopeName -Name "$NmeAppInsightsName" 
    }

    # check if app insights law scope exists
    $AppInsightsLAWScope = Get-AzInsightsPrivateLinkScopedResource -ResourceGroupName $NmeRg -ScopeName $AmplScopeName -Name $NmeAppInsightsLAWName -ErrorAction SilentlyContinue
    if ($AppInsightsLAWScope) {
        Write-Output "Found Azure Monitor App Insights LAW scope"
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
            Write-Output "Found Azure Monitor CCL Insights scope"
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
            Write-Output "Found Azure Monitor CCL LAW scope"
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
        Write-Output "Found Monitor private endpoint"
    } 
    else {
        Write-Output "Configuring monitor service connection and private endpoint"
        $MonitorServiceConnection = New-AzPrivateLinkServiceConnection -Name $MonitorServiceConnectionName -PrivateLinkServiceId $AmplScope.ResourceId -GroupId azuremonitor 
        $MonitorPrivateEndpoint = New-AzPrivateEndpoint -Name "$MonitorPrivateEndpointName" -ResourceGroupName $NmeRg -Location $NmeRegion -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $MonitorServiceConnection 
    }

    # check if monitor dns zone group is created
    $MonitorDnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$MonitorPrivateEndpointName" -ErrorAction SilentlyContinue
    if ($MonitorDnsZoneGroup) {
        Write-Output "Found Monitor DNS zone group"
    } else {
        Write-Output "Configuring monitor DNS zone group"
        $Configs = @()
        # create private dns zone configs for monitor, ops, oms, and monitor agent
        $Configs += New-AzPrivateDnsZoneConfig -Name $MonitorDnsZoneName -PrivateDnsZoneId $MonitorDnsZone.ResourceId
        $Configs += New-AzPrivateDnsZoneConfig -Name $OpsDnsZoneName -PrivateDnsZoneId $OpsDnsZone.ResourceId
        $Configs += New-AzPrivateDnsZoneConfig -Name $OdsDnsZoneName -PrivateDnsZoneId $OdsDnsZone.ResourceId
        $Configs += New-AzPrivateDnsZoneConfig -Name $MonitorAgentDnsZoneName -PrivateDnsZoneId $MonitorAgentDnsZone.ResourceId
        $MonitorDnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName "$MonitorPrivateEndpointName" -Name $MonitorPrivateDnsZoneGroupName -PrivateDnsZoneConfig $Configs
    }


}
#endregion

# region create hybrid worker vm
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

    Write-Warning "The hybrid worker VM is not a PaaS service. As such, you will be responsible for patching the VM $VMName."
    Write-Warning "The hybrid worker VM $VMName will be created with a random local admin password. This password can be reset using the Azure Portal."

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
            Write-Output "NIC $azureNicName already created"
        }
        else {
            Write-Output "Creating hybrid worker NIC"
            $azureNIC = New-AzNetworkInterface -Name $azureNicName -ResourceGroupName $ResourceGroupName -Location $azureLocation -SubnetId $Subnet.Id 
        }

        # Check if VM already exists
        $vm = Get-AzVM -Name $VMName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        if ($vm) {
            Write-Output "Hybrid Worker VM $VMName already created"
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
            Write-Output "Hybrid worker group $HybridWorkerGroupName already created"
        }
        else {
            Write-Output "Creating hybrid worker group"
            $HybridWorkerGroup = New-AzAutomationHybridRunbookWorkerGroup -ResourceGroupName $ResourceGroupName -AutomationAccountName $AA.AutomationAccountName -Name $HybridWorkerGroupName
        }

        # Check if hybrid worker already exists
        $HybridWorker = Get-AzAutomationHybridRunbookWorker -ResourceGroupName $ResourceGroupName -AutomationAccountName $AA.AutomationAccountName -HybridRunbookWorkerGroupName $HybridWorkerGroupName -ErrorAction silentlycontinue

        if ($HybridWorker) {
            Write-Output "Hybrid worker already created"
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
                        -uri "https://$AzureManagementApi/subscriptions/$($context.subscription.id)/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/$($AA.AutomationAccountName)?api-version=2021-06-22" `
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
                            -TypeHandlerVersion 1.1 `
                            -Settings $settings `
                            -EnableAutomaticUpgrade $true
        
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

        write-output "Creating runbook to import automation certificate to hybrid worker vm and install Az modules"
        $Script > .\Ensure-CertAndModulesAreImported.ps1 
        $ImportRunbook = Import-AzAutomationRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $aa.AutomationAccountName -Path .\Ensure-CertAndModulesAreImported.ps1 -Type PowerShell -Name "Import-CertAndModulesToHybridRunbookWorker" -Force
        $PublishRunbook = Publish-AzAutomationRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $aa.AutomationAccountName -Name "Import-CertAndModulesToHybridRunbookWorker" 
        write-output "Importing certificate and installing Az modules on hybrid worker vm"
        $Job = Start-AzAutomationRunbook -Name "Import-CertAndModulesToHybridRunbookWorker" -ResourceGroupName $ResourceGroupName -AutomationAccountName $aa.AutomationAccountName -RunOn $HybridWorkerGroupName

        Do {
            if ($job.status -eq 'Failed') {
            Write-Output "Job to import certificate and az modules to hybrid worker failed"
            Throw $job.Exception
            }
            if ($job.Status -eq 'Stopped') {
            write-output "Job to import certificate to hybrid worker was stopped in Azure. Please import the Nerdio manager certificate and az modules to hybrid worker vm manually"
            }
            write-output "Waiting for certificate import/module install job to complete"
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
        Write-Error "Script to join hybrid worker:" -ErrorAction Continue
        Get-Content .\Ensure-CertAndModulesAreImported.ps1 | Write-Error -ErrorAction Continue
        write-output "Encountered error. Hybrid Worker VM $HybridWorkerVMName has been created but is not configured. Original error:"
        write-output $_
        Write-Warning "Encountered error. Hybrid Worker VM $HybridWorkerVMName has been created but is not configured."
        <#
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
        #>
        Throw $_ 
    }


}

if ($MakeSaStoragePrivate -eq 'True') {
    # check if scripted action automation account has hybrid worker group
    #$HybridWorkerGroup = Get-AzAutomationHybridWorkerGroup -ResourceGroupName $NmeRg -AutomationAccountName $NmeScriptedActionsAccountName 

    
    Write-Output "Checking for hybrid worker VM for scripted actions automation account"
    Try {
        New-NmeHybridWorkerVm -VnetName $PrivateLinkVnetName -SubnetName $PrivateEndpointSubnetName -VMName $HybridWorkerVMName -VMSize $HybridWorkerVMSize -ResourceGroupName $NmeRg -HybridWorkerGroupName $HybridWorkerGroupName -AutomationAccountName $NmeScriptedActionsAccountName -Prefix $Prefix -ErrorAction Stop
        $NewHybridWorker = $true

    }
    catch {
        Write-Output "Unable to create hybrid worker VM for scripted actions automation account. See exception for details"
        Throw $_
    }
    
}
#endregion

# region create private link peering
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
if ($MakeSaStoragePrivate -eq 'True') {
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
# check if endpoint integration enabled
if ($webApp.Properties.virtualNetworkSubnetId -eq $AppServiceSubnet.id) {
    Write-Output "App service VNet integration already enabled"
} 
else {
    Write-Output "Enabling app service VNet integration"
    $webApp.Properties.virtualNetworkSubnetId = $AppServiceSubnet.id
    $webApp.Properties.vnetRouteAllEnabled = 'true'
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
        $CclWebApp.Properties.vnetRouteAllEnabled = 'true'
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
        $IiwWebApp.Properties.vnetRouteAllEnabled = 'true'
        $IiwWebApp = $IiwWebApp | Set-AzResource -Force
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

# region make resources private

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

if ($MakeSaStoragePrivate -eq 'True') {
    # check if deny rule for storage exists
    $StorageAccount = Get-AzStorageAccount -ResourceGroupName $NmeRg | Where-Object StorageAccountName -Match 'cssa'
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

$webApp = Get-AzResource -Id $NmeWebApp.id 
if ($MakeAppServicePrivate -eq 'True') {
    $webApp.Properties.publicNetworkAccess = "Disabled"
    $webApp | Set-AzResource -Force | Out-Null
}
else {
    $webApp.Properties.publicNetworkAccess = "Enabled"
    $webApp | Set-AzResource -Force | Out-Null
}


if ($NewHybridWorker) {
    Write-Output "Hybrid worker group '$HybridWorkerGroupName' has been created. Please update Nerdio Manager to use the new hybrid worker. (Settings->Nerdio Environment->Azure runbooks scripted actions. Click `"Enabled`" and select the new hybrid worker.)"
    Write-Warning "Hybrid worker group '$HybridWorkerGroupName' has been created. Please update Nerdio Manager to use the new hybrid worker. (Settings->Nerdio Environment->Azure runbooks scripted actions. Click `"Enabled`" and select the new hybrid worker.)"
}

# restart the app service
Write-Output "Restarting app service"
$restart = Restart-AzWebApp -ResourceGroupName $NmeRg -Name $NmeWebApp.Name