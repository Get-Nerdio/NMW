#description: Restrict access to the sql database and keyvault used by Nerdio Manager.
#tags: Nerdio, Preview
# test-run: BATCH1-attempt3-storage-acl-guard

<# Notes:
 
This script will add private endpoints and service endpoints to allow the Nerdio Manager app service to communicate
with the sql database, keyvault, and automation account over a private network. Access to the sql database and
keyvault will be restricted to the private network.

What this script does NOT make private, so that the scope is not overstated:

 - The automation accounts. Both the Nerdio Manager automation account and the scripted actions automation account get
   private endpoints, but their public network access is deliberately left enabled. Disabling it on an Automation
   account restricts runbook execution to Hybrid Runbook Workers - Azure sandbox jobs stop working - which would break
   scripted actions for any deployment that does not run everything on hybrid workers. The private endpoints use the
   DSCAndHybridWorker sub-resource only; the Webhook sub-resource is not configured.
 - The secondary sql server, if geo-replication is configured. It is detected but gets no private endpoint and no
   public access restriction, because it is typically in a different region and would need its own VNet, private
   endpoint and DNS zone link.
 - Azure Monitor, Application Insights and Log Analytics. Making these private requires an Azure Monitor Private Link
   Scope, which is out of scope for this script by design - configure AMPLS separately if you need it.
 - Azure Resource Manager control plane traffic (management.azure.com), which is not private-linkable here.

Alongside disabling public network access, this script applies two Microsoft baseline settings to the storage accounts
it manages (minimum TLS version 1.2, and anonymous public blob access disallowed) and sets a minimum TLS version of 1.2
on the sql servers it manages. These are only ever raised, never lowered, so an account already requiring a newer TLS
version keeps it. Shared key access on the storage accounts is deliberately left alone, because Nerdio Manager may
depend on it.

Storage accounts and sub-resources covered. Azure allows exactly one sub-resource per private endpoint, so each entry
below is one endpoint. Anything not listed keeps resolving over the public endpoint even after this script runs, which
is what makes this table worth checking when a new component is added:

 - Scripted actions storage account - blob only, and for both the Private and Restricted values of
   CssaStorageAccount (not Public).
 - Cost Calculator (CCL) storage account - blob only.
 - Deployment/Provisioning (DPS) storage account - blob only.
 - Real Time Insights storage account - table only. Real Time Insights uses the table API and does not use blob, so
   this endpoint deliberately does not request the blob sub-resource.

No queue or file sub-resource endpoints are created, because no Nerdio Manager component requests them. Adding one
means adding its private DNS zone name to the cloud if/else near the top of this script and one entry to the
$StorageSubresourceDnsZoneNames map.

Consequences of disabling public network access on the key vaults. This blocks the trusted-services path as well as the
public path, so scenarios that rely on it stop working: App Service certificate binding from Key Vault, ARM template
reference() to a secret, and Azure Backup are the common ones. If you depend on any of those, they must be reworked to
use the private endpoint or the vault must be left public. The script also sets the trusted-services bypass to None;
that is redundant once public network access is Disabled, and is set for clarity rather than effect.

Recovering from a lockout. Every restriction this script applies is reversible only from the Azure Portal (or the CLI)
- not by re-running this script, which never re-enables public network access on anything. Before disabling anything,
the script now resolves the Nerdio Manager key vault, primary sql server and DPS storage account FQDNs from inside the
VNet-integrated app service worker (via the Kudu/SCM command API), against the VNet's own DNS servers, and TCP-connects
to whatever IP comes back. If any of those three checks fails - the resolved IP is not the private endpoint's IP, or
the TCP connect fails - the script aborts before the make-private region runs and changes nothing. This probe is
skipped with a warning (not an error) when the app service's SCM endpoint cannot be reached, which is the normal case
when re-running this script against a deployment that is already private: disabling public network access on the app
service also blocks its own Kudu endpoint. In that case the script falls back to the weaker private-DNS-zone-record
check described below and proceeds. If Nerdio Manager cannot reach its key vault or database after this script runs
anyway, re-enable public network access on the key vault and the sql server in the portal, confirm the private DNS
records exist and resolve, and then re-run. The most common causes are private DNS records that had not propagated
when public access was disabled, and a pre-existing network security group on the private endpoint subnet whose rules
this script has never inspected but has, by enabling privateEndpointNetworkPolicies, caused to be enforced (also
warned about).

App service subnet sizing. The AppServiceSubnetRange default is a /26. Microsoft recommends a /26 for App Service
regional VNet integration: scale-out and in-place plan changes each temporarily double IP consumption, and up to four
apps (Nerdio Manager, CCL, Intune Insights, Real Time Insights) integrate into this one subnet. The address range is
ignored when the subnet already exists, so a subnet created too small on a first run cannot be widened by re-running
this script - it has to be recreated, which means removing the VNet integration from every app first.

If other NME components, such as Intune Insights, Cost Calculator, or Real Time Insights have been enabled, they will
be added to the private network with private endpoints. The script can be re-run to add additional components to the
private networking.

The MakeAppServicePrivate parameter can be set to 'true' to further limit access to the app service to clients on the
private network or peered networks. Supplying ResourceIds for one ore more existing networks will cause those networks
to be peered to the new private network. MakeAppServicePrivate governs both the primary Nerdio Manager app service and
the Intune Insights app service: Intune Insights is iframed into the Nerdio Manager interface, so it has to be
reachable by exactly the same clients as the primary app service, and tying it to the same parameter keeps the two
consistent instead of letting an admin create a broken combination. If the Cost Calculator (CCL) is deployed, its web
app is always made private, regardless of this parameter: the only thing that communicates with it is the primary
Nerdio Manager web app, over the private network. Real Time Insights has its own MakeRtiAppServicePrivate parameter,
defaulting to 'false', because making it private cuts off any reporting endpoint (AVD session hosts, Windows 365 Cloud
PCs, Intune-managed devices) that lacks line-of-sight to the private VNet, and that failure is silent - see the
MakeRtiAppServicePrivate parameter description for details before enabling it.

This script never re-enables public network access on anything. Setting MakeAppServicePrivate or
MakeRtiAppServicePrivate back to 'false' on a later run leaves the corresponding app service private; re-enable
public access in the Azure Portal if that is what you want.

If the VNet and Subnets already exist, the existing resources will be used and address ranges will not be changed. 
If they do not exist, they will be created. Names for resources created by this script, such as private endpoint names, 
can be customized by cloning this script and editing the variables at the top of the script.

The CssaStorageAccount parameter controls network access to the scripted actions storage account, and defaults to
Restricted. Private and Restricted both put the account on the private vnet (blob sub-resource only - see the storage
sub-resource list above); Public leaves it exactly as found, matching this script's old default behavior. Private also
fully disables the account's public network access, so AVD VMs need PeerVnetIds (or another private endpoint) to reach
it at all. Restricted leaves the public endpoint reachable but firewalls it to VNets tagged as linked to Nerdio Manager
(LINKED_NETWORK) - found across every subscription this service principal can read, not just this one - whose subnet
already has the Microsoft.Storage service endpoint enabled; a linked AVD VNet without that service endpoint enabled on
its subnet will lose access to the storage account under Restricted, so enable it there before relying on the default.
 
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
    "Description": "Address range for app service subnet. Ignored if subnet already exists. A /26 is the Microsoft recommendation for App Service regional VNet integration: scale-out and in-place plan changes each temporarily double IP consumption, and up to four Nerdio Manager apps integrate into this one subnet. Because the range is ignored once the subnet exists, a subnet created too small cannot be widened by re-running this script - it has to be recreated, which means removing the VNet integration from every app first.",
    "IsRequired": false,
    "DefaultValue": "10.250.251.0/26"
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
    "Description": "Controls network access to the scripted actions storage account. 'Restricted' (default): the account gets a private endpoint (blob sub-resource) and stays reachable on its public endpoint, but the public endpoint's firewall denies all traffic except from VNets tagged as linked to Nerdio Manager (LINKED_NETWORK) whose subnet already has the Microsoft.Storage service endpoint enabled - found across every subscription this service principal can read, not just this one. 'Public': no private endpoint, no firewall change - the account is left exactly as found, matching this script's old default behavior. 'Private': private endpoint plus public network access fully disabled, matching this script's previous default-parameter-off behavior - AVD hosts then need a private endpoint or VNet peering (see PeerVnetIds) to reach the account at all. This script never relaxes a more restrictive setting back to a less restrictive one on a later run: moving from Private to Restricted or Public requires re-enabling public network access on the storage account in the Azure Portal first.",
    "IsRequired": false,
    "DefaultValue": "Restricted"
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
  "MakeRtiAppServicePrivate": {
    "Description": "WARNING: If set to true, only clients with network line-of-sight to the private VNet or a peered VNet will be able to reach the Real Time Insights app service. Every endpoint that reports to Real Time Insights - AVD session hosts, Windows 365 Cloud PCs and Intune-managed devices - must be able to reach it to post metrics, and devices that cannot will simply stop reporting with no error surfaced in Nerdio Manager; the symptom is missing history noticed weeks later. Intune-managed devices are typically internet-based and roaming with no VNet line-of-sight, and Cloud PCs on a Microsoft-hosted network have no customer VNet at all - neither can be recovered by peering. AVD session hosts in customer Azure VNets can be recovered by peering their VNet via PeerVnetIds and ensuring DNS resolves the app service FQDN to the private endpoint. Leave this false unless you have confirmed every reporting population can reach the private VNet. Note that setting this back to false does NOT re-enable public access on a later run - this script never re-enables public network access implicitly. To undo it, re-enable public network access on the app service in the Azure Portal.",
    "IsRequired": false,
    "DefaultValue": "false"
  },
  "SkipDNS": {
    "Description": "WARNING: Skip all DNS operations including checking for existing private DNS zones, creating new DNS zones, and linking DNS zones to VNets. Use this only if you are managing DNS yourself. With this set to true the private endpoints are created with no DNS zone groups, so nothing resolves to them until you configure DNS - while the same run may still disable public network access on the key vault and sql server, which locks Nerdio Manager out. The private DNS records must exist and resolve before the make-private steps take effect. If that happens, re-enable public network access on the key vault and sql server in the Azure Portal, fix DNS, and re-run.",
    "IsRequired": false,
    "DefaultValue": "false"
  }
}
#>
 
$ErrorActionPreference = 'Stop'

# Explicit module check rather than #Requires -Modules. A #Requires failure inside the Azure
# Automation sandbox surfaces as an opaque error that does not name the missing module, and pinning
# minimum versions is risky across commercial and US Gov, where available module versions differ.
# Microsoft.Graph.Applications is deliberately not in this list: it is only needed by the
# GetEntAppName recovery path, which installs it on demand.
$RequiredModules = @(
    'Az.Accounts'
    'Az.Resources'
    'Az.KeyVault'
    'Az.Sql'
    'Az.Storage'
    'Az.Websites'
    'Az.Network'
    'Az.Automation'
)
$MissingModules = @($RequiredModules | Where-Object { -not (Get-Module -ListAvailable -Name $_) })
if ($MissingModules.Count) {
    Throw "This script requires the following PowerShell modules, which are not available in this Automation account: $($MissingModules -join ', '). Add them to the Nerdio Manager scripted actions automation account (Modules -> Browse gallery) and re-run this script."
}

# Nerdio Manager passes these parameters in as strings. Normalize them to real booleans once, here,
# rather than comparing against 'True' at each use site with inconsistent casing. Doing the
# conversion up front also means a typo like "yes" or "1" is caught before the script changes
# anything, instead of being silently treated as false.
function ConvertTo-NmeBoolean {
    param(
        [string]$Value,
        [Parameter(Mandatory=$true)][string]$Name
    )
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    switch ($Value.Trim().ToLowerInvariant()) {
        'true'  { return $true }
        'false' { return $false }
        '1'     { return $true }
        '0'     { return $false }
        'yes'   { return $true }
        'no'    { return $false }
        default { Throw "The $Name parameter must be true or false, but was '$Value'." }
    }
}

# Three-valued equivalent of ConvertTo-NmeBoolean above, for CssaStorageAccount: 'Restricted' is the
# default rather than throwing on blank, since NME may pass an empty string for a parameter left at
# its default rather than the literal default value.
function ConvertTo-NmeCssaStorageMode {
    param(
        [string]$Value,
        [Parameter(Mandatory=$true)][string]$Name
    )
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'Restricted' }
    switch ($Value.Trim().ToLowerInvariant()) {
        'restricted' { return 'Restricted' }
        'public'     { return 'Public' }
        'private'    { return 'Private' }
        default { Throw "The $Name parameter must be Restricted, Public, or Private, but was '$Value'." }
    }
}

$CssaStorageAccount       = ConvertTo-NmeCssaStorageMode -Value $CssaStorageAccount -Name 'CssaStorageAccount'
$MakeAppServicePrivate    = ConvertTo-NmeBoolean -Value $MakeAppServicePrivate    -Name 'MakeAppServicePrivate'
$MakeRtiAppServicePrivate = ConvertTo-NmeBoolean -Value $MakeRtiAppServicePrivate -Name 'MakeRtiAppServicePrivate'
$SkipDNS                  = ConvertTo-NmeBoolean -Value $SkipDNS                  -Name 'SkipDNS'

# Reject parameter combinations where one parameter silently discards another, before anything is
# created. Both of these were previously accepted and then quietly ignored further down, which looks
# like the script honored a setting it actually dropped - the worst kind of failure here, because the
# run reports success while the DNS configuration is not what was asked for.
if ($SkipDNS -and $ExistingDNSZonesRG) {
    Throw "SkipDNS is true and ExistingDNSZonesRG is set to '$ExistingDNSZonesRG', but these are contradictory: SkipDNS skips every DNS operation, including linking existing zones, so ExistingDNSZonesRG would be ignored entirely. Set SkipDNS to false to use the existing zones in '$ExistingDNSZonesRG', or clear ExistingDNSZonesRG to confirm you are managing DNS yourself."
}
if ($ExistingDNSZonesSubId -and -not $ExistingDNSZonesRG) {
    Throw "ExistingDNSZonesSubId is set to '$ExistingDNSZonesSubId' but ExistingDNSZonesRG is empty. The subscription id is only used to locate the resource group holding your existing private DNS zones, so on its own it would be ignored and this script would create new DNS zones in Nerdio Manager's own resource group instead. Set ExistingDNSZonesRG to the resource group holding the zones, or clear ExistingDNSZonesSubId."
}

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
        # $key always has a value by this point (the derivation above falls back to 'NMW_OBJECT_TYPE'),
        # so these if ($key) guards are always true. The else branches they used to have were dead, and
        # three of them ran an unfiltered Get over the whole resource group and bound an arbitrary
        # resource as "the RTI resource" - do not re-add them.
        if ($key){
            $SqlServer = Get-AzSqlServer -ResourceGroupName $nmerg | Where-Object ServerName -NotMatch '-secondary' | Where-Object {$_.tags[$key] -ne 'INTUNE_INSIGHTS_DEPLOYMENT_RESOURCE' -and $_.tags[$key] -ne 'EIDO_DEPLOYMENT_RESOURCE' -and $_.tags[$key] -ne 'REAL_TIME_INSIGHTS_DEPLOYMENT_RESOURCE' -and $_.tags[$key] -ne'NERDIO_COPILOT_DEPLOYMENT_RESOURCE'}
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
    if (!($SqlSecondary)){ $SqlSecondary = Get-AzSqlServer -ResourceGroupName $nmerg | Where-Object ServerName -Match '-secondary' }
    if ($SqlSecondary) {
        $script:NmeSqlSecondaryServerName = $SqlSecondary.ServerName
    }
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

    $script:NmeSubscriptionId = ($NmeWebApp.siteconfig.appsettings | Where-Object name -eq 'Deployment:SubscriptionId').value
    $script:NmeTagPrefix = ($NmeWebApp.siteconfig.appsettings | Where-Object name -eq 'Deployment:AzureTagPrefix').value
    $script:NmeAutomationAccountName = ($NmeWebApp.siteconfig.appsettings | Where-Object name -eq 'Deployment:AutomationAccountName').value
    $script:NmeScriptedActionsAccountName = (($NmeWebApp.siteconfig.appsettings | Where-Object name -eq 'Deployment:ScriptedActionAccount').value).Split("/")[-1]
    $script:NmeRegion = $NmeKeyVault.Location

    # Find Real Time Insights components if they exist
    # Find RTI sql server
    # These lookups are for optional components: a failed tag lookup is expected to fall through to the
    # next discovery method, so the exception is intentionally swallowed here. It is still surfaced on the
    # verbose stream so a throttling error or RBAC denial can be told apart from "not deployed".
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
} else {
    $KeyVaultDnsZoneName = "privatelink.vaultcore.azure.net"
    $SqlDnsZoneName = "privatelink.database.windows.net"
    $AutomationDnsZoneName = "privatelink.azure-automation.net"
    $StorageDnsZoneName = "privatelink.blob.core.windows.net"
    $TableDnsZoneName = "privatelink.table.core.windows.net"
    $AppServiceDnsZoneName = "privatelink.azurewebsites.net"
}
# There is deliberately no Azure Resource Manager endpoint variable here: ARM control-plane traffic
# (management.azure.com / management.usgovcloudapi.net) is not made private by this script. See the
# notes block at the top.

# Storage sub-resource -> private DNS zone. One private endpoint can serve exactly one sub-resource,
# so covering an additional sub-resource means an additional endpoint, not an additional zone config
# on an existing one. Keeping the mapping in one place is what makes that a one-line change: the
# Real Time Insights table-zone bug existed because each storage endpoint hardcoded 'blob' and a
# single zone config. Queue and file are not covered because nothing in NME requests them today; to
# add one, add its zone name to the cloud if/else above and an entry here.
$StorageSubresourceDnsZoneNames = @{
    blob  = $StorageDnsZoneName
    table = $TableDnsZoneName
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

# True only when this job is confirmed running in the older download mode (script fetched from
# scriptUri) rather than Inline Script mode (full script body passed as ScriptBase64). Used to
# warn before restricting the scripted actions storage account's public access, since that
# storage account is also where Azure Automation fetches a download-mode job's own script body -
# see the CssaStorageAccount switch below. Returns $false (not $null) on anything inconclusive,
# so an unresolvable execution mode never triggers a warning it can't actually justify.
function Test-NmeCurrentJobIsDownloadMode {
    try {
        $ThisJob = Get-AzAutomationJob -Id $PSPrivateMetadata['JobId'].Guid -ResourceGroupName $NmeRg -AutomationAccountName $NmeScriptedActionsAccountName
        $ScriptBase64 = Get-NmeJobParameterValue -JobParameters $ThisJob.JobParameters -Name 'ScriptBase64'
        $ScriptUri = Get-NmeJobParameterValue -JobParameters $ThisJob.JobParameters -Name 'scriptUri'
        return ([string]::IsNullOrEmpty($ScriptBase64)) -and (-not [string]::IsNullOrEmpty($ScriptUri))
    }
    catch {
        Write-Verbose "Test-NmeCurrentJobIsDownloadMode failed to resolve this job's execution mode: $($_.Exception.Message)"
        return $false
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
                # Note: Get-AzAutomationJobOutput only returns a truncated summary of each record.
                # If the full, untruncated text is ever needed, use Get-AzAutomationJobOutputRecord -Id <record id> instead.
                foreach ($record in $JobOutput) {
                    $Summary = $record.Summary
                    if ([string]::IsNullOrEmpty($Summary)) {
                        continue
                    }
                    switch ($record.Type) {
                        'Error' {
                            # -ErrorAction Continue is required here: this script sets $ErrorActionPreference = 'Stop',
                            # and a bare Write-Error would throw under that preference, aborting the replay before
                            # reaching the "App Service restarted" message and wait-time calculation below. Do not remove.
                            Write-Error "[previous run] $Summary" -ErrorAction Continue
                        }
                        'Warning' {
                            Write-Warning "[previous run] $Summary"
                        }
                        'Verbose' {
                            Write-Verbose "[previous run] $Summary"
                        }
                        'Debug' {
                            Write-Debug "[previous run] $Summary"
                        }
                        'Progress' {
                            # Progress records were transient UI state in the original run; skip them in the replay.
                        }
                        default {
                            Write-Output "[previous run] $Summary"
                        }
                    }
                }

                Write-Output "App Service restarted after running this script."
                # How much of the cooldown window is left, based on how long ago the app was actually modified.
                $WaitMinutes = [math]::Ceiling($MinutesAgo - ((Get-Date).ToUniversalTime() - $app.LastModifiedTimeUtc).TotalMinutes)
                if ($WaitMinutes -gt 0) {
                    Write-Output "If you need to re-run the script, please wait $WaitMinutes minutes and try again."
                }
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
if ($SkipDNS) {
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
    # Build the complete required-zone list before any lookup: a failure on one of the Get calls below
    # is reported in the catch, and the list has to be complete at that point to be useful.
    $RequiredDnsZones = @($KeyVaultDnsZoneName, $SqlDnsZoneName, $AutomationDnsZoneName, $StorageDnsZoneName, $AppServiceDnsZoneName)
    if ($NmeRtiStorageAccountName) { $RequiredDnsZones += $TableDnsZoneName }
    try {
        # get DNS zones
        $KeyVaultDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name $KeyVaultDnsZoneName -ErrorAction Stop
        $SqlDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name $SqlDnsZoneName -ErrorAction Stop
        $AutomationDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name $AutomationDnsZoneName -ErrorAction Stop
        $StorageDnsZone = Get-AzPrivateDnsZone -ResourceGroupName $DnsRg -Name $StorageDnsZoneName -ErrorAction Stop
        if ($NmeRtiStorageAccountName) {
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
    # Check for an existing rule BY NAME, not just by subnet id. New-AzSqlServerVirtualNetworkRule
    # throws "Virtual Network Rule with name '...' already exists" if a rule with this literal name
    # is already present on the server, regardless of which subnet it points at - unlike the Key
    # Vault path just above this function's call sites (Add-AzKeyVaultNetworkRule), which is safe to
    # call repeatedly. The old `-notcontains $PrivateEndpointSubnetId` check only asked "is our subnet
    # already covered by some rule", so a stale same-named rule left pointing at a *different* subnet
    # (e.g. a fixture VNet's private endpoint subnet from an earlier run against this same SQL server)
    # would pass that check as "not covered" and then collide on the name when this tried to create a
    # second rule. Found live (P1-18) on the first real second-run-against-a-different-VNet scenario.
    $ServerRules = Get-AzSqlServerVirtualNetworkRule -ServerName $ServerName -ResourceGroupName $ResourceGroupName
    $ExistingRule = $ServerRules | Where-Object { $_.VirtualNetworkRuleName -eq 'Allow private endpoint subnet' } | Select-Object -First 1
    if (-not $ExistingRule) {
        New-AzSqlServerVirtualNetworkRule -VirtualNetworkRuleName 'Allow private endpoint subnet' -VirtualNetworkSubnetId $PrivateEndpointSubnetId -ServerName $ServerName -ResourceGroupName $ResourceGroupName | Out-Null
    }
    elseif ($ExistingRule.VirtualNetworkSubnetId -ne $PrivateEndpointSubnetId) {
        # Found → skip, same idiom as the rest of this script (P0-1): report the drift rather than
        # silently leaving it, but do not delete/recreate a customer's existing rule automatically.
        Write-Warning "$DisplayName already has a VNet rule named 'Allow private endpoint subnet' pointing at a different subnet ($($ExistingRule.VirtualNetworkSubnetId)) than this run's private endpoint subnet ($PrivateEndpointSubnetId). Not creating a duplicate - Azure rejects a second rule with the same name. This is harmless once public access is disabled (VNet rules are not evaluated for traffic arriving over a private endpoint), but if you need public access to remain enabled and reachable from the current private endpoint subnet, remove or rename the stale rule in the Azure Portal and re-run."
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

function Set-NmeStorageBaseline {
    # Microsoft's storage security baseline items that are low-risk for these NME-internal accounts:
    # require TLS 1.2 and disallow anonymous public blob access. Applied as an explicit part of
    # "make private" rather than left to the customer. Both are only ever raised, never lowered - an
    # account already requiring TLS 1.3 keeps it. AllowSharedKeyAccess is deliberately NOT touched:
    # NME may depend on shared-key access. A failure here is warned about, never thrown: this runs
    # after key vault and SQL public access have been disabled, and hardening niceties must not
    # abort a run at that point.
    param(
        [Parameter(Mandatory=$true)][string]$ResourceGroupName,
        [Parameter(Mandatory=$true)][string]$StorageAccountName,
        # Used in output messages, e.g. "scripted actions", "CCL", "DPS", "RTI".
        [Parameter(Mandatory=$true)][string]$DisplayName
    )
    try {
        $StorageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction Stop
        $SetParams = @{}
        # TLS1_0 < TLS1_1 < TLS1_2 < TLS1_3, and the property is a string like 'TLS1_2'. Compare by
        # ordinal position in that list so a future TLS1_3 default is not downgraded to TLS1_2.
        $TlsOrder = @('TLS1_0', 'TLS1_1', 'TLS1_2', 'TLS1_3')
        $CurrentTls = [string]$StorageAccount.MinimumTlsVersion
        if ([string]::IsNullOrWhiteSpace($CurrentTls) -or ($TlsOrder.IndexOf($CurrentTls) -lt $TlsOrder.IndexOf('TLS1_2'))) {
            $SetParams['MinimumTlsVersion'] = 'TLS1_2'
        }
        if ($StorageAccount.AllowBlobPublicAccess -ne $false) {
            $SetParams['AllowBlobPublicAccess'] = $false
        }
        if ($SetParams.Count -eq 0) {
            Write-Output "$DisplayName storage account already requires TLS 1.2 and disallows public blob access"
            return
        }
        Write-Output "Applying storage baseline to the $DisplayName storage account ($($SetParams.Keys -join ', '))"
        Set-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName @SetParams | Out-Null
    }
    catch {
        Write-Warning "Unable to apply the storage baseline (TLS 1.2 minimum, no public blob access) to the $DisplayName storage account '$StorageAccountName': $($_.Exception.Message). Set these in the Azure Portal if required."
    }
}

function Set-NmeSqlBaseline {
    # SQL's equivalent baseline item: require TLS 1.2. Only ever raised, never lowered. Warned about
    # rather than thrown for the same reason as Set-NmeStorageBaseline.
    param(
        [Parameter(Mandatory=$true)][string]$ResourceGroupName,
        [Parameter(Mandatory=$true)][string]$ServerName,
        # Used in output messages, e.g. "SQL", "RTI SQL", "Intune Insights SQL".
        [Parameter(Mandatory=$true)][string]$DisplayName
    )
    try {
        $SqlServer = Get-AzSqlServer -ResourceGroupName $ResourceGroupName -ServerName $ServerName -ErrorAction Stop
        # MinimalTlsVersion is a string like '1.2'. An unset value means no minimum is enforced.
        $CurrentTls = [string]$SqlServer.MinimalTlsVersion
        if (-not [string]::IsNullOrWhiteSpace($CurrentTls) -and ([double]$CurrentTls -ge 1.2)) {
            Write-Output "$DisplayName already requires TLS 1.2"
            return
        }
        Write-Output "Setting $DisplayName minimum TLS version to 1.2"
        Set-AzSqlServer -ResourceGroupName $ResourceGroupName -ServerName $ServerName -MinimalTlsVersion '1.2' | Out-Null
    }
    catch {
        Write-Warning "Unable to set the minimum TLS version to 1.2 on $DisplayName server '$ServerName': $($_.Exception.Message). Set it in the Azure Portal if required."
    }
}

function New-NmeStoragePrivateEndpoint {
    # This function depends on script scope: it reads $ExistingPrivateEndpoints, $NmeRg,
    # $VnetLocation, $PrivateEndpointSubnet, $SkipDNS, $StorageSubresourceDnsZoneNames and
    # $StorageSubresourceDnsZones, all of which must be set before this function is called.
    param(
        [Parameter(Mandatory=$true)]$StorageAccount,          # the object from Get-AzStorageAccount
        [Parameter(Mandatory=$true)][string]$Subresource,     # 'blob' or 'table'
        [Parameter(Mandatory=$true)][string]$PrivateEndpointName,
        [Parameter(Mandatory=$true)][string]$ServiceConnectionName,
        [Parameter(Mandatory=$true)][string]$DnsZoneGroupName,
        [Parameter(Mandatory=$true)][string]$DisplayName      # e.g. 'scripted actions', 'CCL', 'DPS', 'RTI'
    )
    if (-not $StorageSubresourceDnsZoneNames.ContainsKey($Subresource)) {
        Throw "New-NmeStoragePrivateEndpoint: internal error - no DNS zone name is mapped for storage sub-resource '$Subresource'. Add it to `$StorageSubresourceDnsZoneNames."
    }
    $ZoneName = $StorageSubresourceDnsZoneNames[$Subresource]
    $Zone = $StorageSubresourceDnsZones[$Subresource]

    $Endpoint = $ExistingPrivateEndpoints | Where-Object { $_.PrivateLinkServiceConnections.PrivateLinkServiceId -eq $StorageAccount.Id }
    if ($Endpoint) {
        Write-Output "Found $DisplayName storage private endpoint"
        # Earlier versions of this script created some storage endpoints with a hardcoded sub-resource that
        # did not always match the account's actual storage API (see the Real Time Insights table-zone bug).
        # A private endpoint's sub-resource (groupId) cannot be changed in place - it has to be recreated.
        $GroupIds = $Endpoint.PrivateLinkServiceConnections.GroupIds
        if ($GroupIds -notcontains $Subresource) {
            Write-Warning "The existing $DisplayName storage private endpoint '$($Endpoint.Name)' uses the '$($GroupIds -join ',')' sub-resource, but $DisplayName requires the '$Subresource' sub-resource. $Subresource storage traffic will continue to use the public endpoint. A private endpoint's sub-resource cannot be changed in place: delete the private endpoint '$($Endpoint.Name)' in the Azure Portal and re-run this script to have it recreated correctly."
        }
    }
    else {
        Write-Output "Configuring $DisplayName storage service connection and private endpoint"
        $ServiceConnection = New-AzPrivateLinkServiceConnection -Name $ServiceConnectionName -PrivateLinkServiceId $StorageAccount.Id -GroupId $Subresource
        $Endpoint = New-AzPrivateEndpoint -Name $PrivateEndpointName -ResourceGroupName $NmeRg -Location $VnetLocation -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $ServiceConnection
    }

    if ($SkipDNS) {
        Write-Output "Skipping $DisplayName storage DNS zone group configuration (SkipDNS enabled)"
        return $Endpoint
    }

    $DnsZoneGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $Endpoint.Name -ErrorAction SilentlyContinue
    if ($DnsZoneGroup) {
        Write-Output "Found $DisplayName storage DNS zone group"
        # Earlier versions of this script linked some zone groups to the wrong zone for the account's sub-resource
        if ($DnsZoneGroup.PrivateDnsZoneConfigs.PrivateDnsZoneId -notcontains $Zone.ResourceId) {
            Write-Warning "The existing $DisplayName storage DNS zone group '$($DnsZoneGroup.Name)' is not linked to the '$ZoneName' private DNS zone, so $DisplayName $Subresource storage will not resolve to the private endpoint. Delete the private endpoint '$($Endpoint.Name)' in the Azure Portal and re-run this script to have the endpoint and its DNS zone group recreated correctly."
        }
    }
    else {
        Write-Output "Configuring $DisplayName storage DNS zone group"
        $Config = New-AzPrivateDnsZoneConfig -Name $ZoneName -PrivateDnsZoneId $Zone.ResourceId
        $DnsZoneGroup = New-AzPrivateDnsZoneGroup -ResourceGroupName $NmeRg -PrivateEndpointName $Endpoint.Name -Name $DnsZoneGroupName -PrivateDnsZoneConfig $Config
    }

    return $Endpoint
}

function Test-NmePrivateDnsResolution {
    # FALLBACK ONLY, used when the real connectivity probe (Test-NmeAppServiceConnectivity, run from
    # inside the VNet-integrated app service worker via Kudu) could not run - most commonly because
    # public network access on the app service was already disabled by an earlier run, which also
    # blocks its own SCM/Kudu endpoint. This function does not prove Nerdio Manager can actually reach
    # or resolve anything: it only proves the Azure private DNS zone contains an A record for the
    # resource. It says nothing about whether that zone is linked to the right VNet, whether DNS is
    # actually being consulted by the worker, or about routing and NSGs - and it is useless entirely
    # when SkipDNS is true, since a customer running their own DNS may have no Azure private DNS zone
    # to check. Diagnostic only - never blocks. Runs before the make-private region so a missing
    # private DNS record is reported *before* public access is disabled, which is the point at which
    # it stops being recoverable from inside Nerdio Manager.
    #
    # Deliberately does NOT use Resolve-DnsName. This script executes in the Azure Automation
    # sandbox, which sits outside the VNet and therefore does not use the private DNS zones linked
    # to it - a lookup from here would fail even on a correctly configured deployment. Instead it
    # asks Azure whether the private DNS zone actually contains an A record for the resource, which
    # is what the private endpoint's DNS zone group is responsible for creating.
    param(
        [Parameter(Mandatory=$true)][string]$ZoneName,
        [Parameter(Mandatory=$true)][string]$ZoneResourceGroupName,
        [Parameter(Mandatory=$true)][string]$RecordName,   # the resource's short name, e.g. the vault name
        [Parameter(Mandatory=$true)][string]$DisplayName   # e.g. "Nerdio Manager key vault"
    )
    try {
        $RecordSet = Get-AzPrivateDnsRecordSet -ResourceGroupName $ZoneResourceGroupName -ZoneName $ZoneName -Name $RecordName -RecordType A -ErrorAction SilentlyContinue
        if ($RecordSet -and @($RecordSet.Records).Count -gt 0) {
            return $true
        }
        Write-Warning "No A record for '$RecordName' was found in private DNS zone '$ZoneName' (resource group '$ZoneResourceGroupName') for the $DisplayName. This record is normally created within a minute or two of the private endpoint being provisioned. This script is about to disable public network access on the $DisplayName; if the record has not propagated yet, the next scripted action run may not be able to reach it. The recovery path is to re-enable public network access on the $DisplayName in the Azure Portal."
        return $false
    }
    catch {
        Write-Verbose "Test-NmePrivateDnsResolution: unable to check private DNS zone '$ZoneName' for record '$RecordName' ($($_.Exception.Message)). Treating this check as passed since it is diagnostic only."
        return $true
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

function Invoke-NmeKuduCommand {
    # Runs a PowerShell script inside the VNet-integrated app service worker via the Kudu/SCM
    # /api/command endpoint. This is how the script observes what the worker process can actually
    # resolve and reach, rather than what Azure Resource Manager reports about the private endpoints
    # and DNS zones it created - the two can disagree (DNS not yet propagated, a blocking NSG, bad
    # routing) and ARM has no visibility into that disagreement.
    param(
        [Parameter(Mandatory=$true)][string]$ScmHost,
        [Parameter(Mandatory=$true)][string]$ScriptText
    )

    # Newer Az.Accounts returns .Token as a SecureString rather than a plain string. This dual
    # handling is deliberate: this script has to run against whatever Az.Accounts version happens to
    # be installed in the customer's Automation account, and there is no way to know which shape it
    # will return ahead of time.
    $RawToken = (Get-AzAccessToken -ResourceUrl (Get-AzContext).Environment.ResourceManagerUrl -ErrorAction Stop).Token
    $KuduToken = if ($RawToken -is [System.Security.SecureString]) {
        [System.Net.NetworkCredential]::new("", $RawToken).Password
    } else {
        $RawToken
    }

    # Send the remote script base64-encoded via -EncodedCommand rather than as an inline quoted
    # string. An inline string would have to survive three layers of quoting - the local PowerShell
    # string, the JSON request body, cmd.exe, and the remote powershell -Command parser - and that is
    # the usual source of breakage in this pattern. -EncodedCommand requires UTF-16LE, hence Unicode
    # (not UTF8) below.
    $EncodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($ScriptText))
    $RemoteCommand = "powershell -NoProfile -EncodedCommand $EncodedCommand"

    # Kudu's /api/command runs $RemoteCommand through cmd.exe, which enforces an ~8191-character total
    # command-line length (CreateProcess's own limit is much higher; this is cmd.exe's own, lower one).
    # Exceeding it is NOT reported as a clear error from Kudu: it returns HTTP 200 with ExitCode 1 and
    # Error "The command line is too long.", which - unless the caller inspects those fields - looks
    # identical to "the remote script ran and every target failed" (every result field blank). That is
    # exactly what happened here: T01's connectivity gate failed on its first three live runs with a
    # blank result for every target, and two earlier guesses (DNS/VNet-integration warm-up timing, then
    # an unrelated Content-Type-header change) were tried and failed before Write-Verbose logging of
    # the raw Response.Error surfaced this message. The immediate fix was trimming
    # $RemoteScriptTemplate's payload size (see Test-NmeAppServiceConnectivity), but a real
    # NME deployment can have longer FQDNs than this lab's, so fail clearly here too rather than risk
    # the same silent-looking failure recurring for a customer with long resource names.
    if ($RemoteCommand.Length -gt 8000) {
        Throw "Invoke-NmeKuduCommand: the command to run on the app service worker is $($RemoteCommand.Length) characters, over the safe threshold for cmd.exe's command-line length limit (Kudu's /api/command runs commands through cmd.exe, which caps total command-line length at roughly 8191 characters). Sending it anyway would likely fail with Kudu returning ExitCode 1 and Error 'The command line is too long.', which the caller cannot distinguish from a real probe failure. This is almost always caused by long resource FQDNs multiplying across several targets; if this is the connectivity probe, consider it a sign this deployment's resource names are unusually long and would need protocol changes (e.g. writing the remote script to a temp file via Kudu's VFS API instead of -EncodedCommand) to support reliably."
    }

    $Body = @{ command = $RemoteCommand; dir = 'site\wwwroot' } | ConvertTo-Json
    # Content-Type goes through -ContentType rather than $Headers - the idiomatic way to set it on
    # Invoke-RestMethod. (This was tried as a fix for the failure described above before the real cause
    # - command-line length - was found; keeping it since it is still correct practice, not because it
    # was the fix.)
    $Headers = @{ Authorization = "Bearer $KuduToken" }

    # Exceptions propagate to the caller - it decides what a failed Kudu call means (see the
    # connectivity gate below, which treats it as "could not run the probe", not as a failed probe).
    $Response = Invoke-RestMethod -Method POST -Uri "https://$ScmHost/api/command" -Headers $Headers -ContentType 'application/json' -Body $Body -TimeoutSec 180 -ErrorAction Stop

    # Kudu's /api/command returns HTTP 200 even when the remote command itself failed (non-zero exit,
    # or a cmd.exe-level rejection like the command-line-length case above) - ExitCode/Error are the
    # only signal, and Invoke-RestMethod's -ErrorAction Stop above does not see either as an HTTP-level
    # failure. Surface a non-zero exit as a real error rather than silently returning empty Output,
    # which is what let the command-line-length bug look like "the probe ran and found nothing" for
    # three live runs before Write-Verbose logging of these exact fields caught it.
    if ($Response.ExitCode -ne 0) {
        Throw "Invoke-NmeKuduCommand: the remote command on the app service worker exited with code $($Response.ExitCode): $($Response.Error)"
    }

    return $Response.Output
}

function Test-NmeAppServiceConnectivity {
    # Runs a real connectivity probe from inside the VNet-integrated app service worker: for each
    # target, resolve its FQDN against a specific VNet DNS server and TCP-connect to whatever comes
    # back. This is a probe, not a DNS flush - it proves the DNS server is reachable through VNet
    # integration and holds the expected record, but it does not change what the app worker process
    # itself is currently resolving against (that would require restarting the app, which this script
    # deliberately avoids - explicit DNS-server targeting is what makes a restart or retry loop
    # unnecessary here).
    param(
        [Parameter(Mandatory=$true)][string]$ScmHost,
        [Parameter(Mandatory=$true)][string[]]$DnsServer,
        [Parameter(Mandatory=$true)]$Target   # array of pscustomobject: Name, Fqdn, Port, ExpectedIp
    )

    # Build the three interpolated lists once, locally, then splice them into a single-quoted (fully
    # literal) remote script template. Keeping the template single-quoted avoids having to escape `$`
    # and backtick characters that are meant to be evaluated on the REMOTE side rather than here.
    $FqdnList = ($Target | ForEach-Object { "'$($_.Fqdn -replace "'", "''")'" }) -join ','
    $PortMap = ($Target | ForEach-Object { "'$($_.Fqdn -replace "'", "''")'='$($_.Port)'" }) -join ';'
    $DnsServerList = ($DnsServer | ForEach-Object { "'$($_ -replace "'", "''")'" }) -join ','

    # $ErrorActionPreference = 'SilentlyContinue' plus a try/catch around every step for every target,
    # so a single bad target (typo'd FQDN, a missing tool) cannot kill the loop and silently skip the
    # remaining targets. Emits exactly one '<fqdn>|<resolvedip>|<OK|FAIL>|<dns method>|<tcp method>'
    # line per target.
    #
    # DNS: tries each supplied DNS server in turn via `nameresolver <fqdn> <server>` until one returns
    # something usable. Parsing approach matches NmeNetworkTest.ps1: keep lines that are not the
    # "Server:" line and that end in an IPv4 address, trim, strip a leading "Addresses:" label, and
    # take the first one. If nameresolver is missing or returns nothing usable, falls back to .NET DNS
    # resolution, which cannot target a specific server (it uses whatever the worker is currently
    # configured to use) and is therefore a weaker signal - reported as such via $dnsMethod ('dotnet').
    #
    # TCP: `tcpping <ip>:<port>` is tried first, since it's the tool Microsoft documents for testing
    # outbound connectivity from an App Service worker. If it's missing or its output doesn't match,
    # falls back to a raw TcpClient connect, whose behavior doesn't depend on a tool being present or
    # on its output format.
    #
    # IMPORTANT - this template is embedded verbatim (via the __PLACEHOLDER__ substitutions below) into
    # a command sent to the remote worker as `powershell -EncodedCommand <base64>`, executed through
    # Kudu's /api/command endpoint, which runs it via cmd.exe. cmd.exe enforces an ~8191-character
    # total command-line length; with realistic FQDNs for even 3 targets, the base64-encoded payload
    # comfortably exceeds that once comments and blank lines are included, and Kudu's failure mode for
    # an over-length command line is NOT an error it surfaces clearly - it returns HTTP 200 with
    # ExitCode 1 and Error "The command line is too long.", which looks from the caller's side exactly
    # like "the probe ran and found nothing reachable" (every result field blank) rather than "the
    # request itself couldn't run". This bit T01 for real: two earlier (wrong) diagnoses - DNS/VNet
    # warm-up timing, then an unrelated Content-Type header change - were tried and failed before the
    # real cause was found via the diagnostic Write-Verbose calls in Invoke-NmeKuduCommand, which log
    # the raw Response.Error. Keep this template comment-free and as short as correctness allows; do
    # not "restore readability" by adding comments back inside the @' '@ block below. The commentary
    # above (outside the string) is the right place for that.
    $RemoteScriptTemplate = @'
$ErrorActionPreference = 'SilentlyContinue'
$fqdns = @(__FQDNS__)
$ports = @{ __PORTS__ }
$dnsServers = @(__DNSSERVERS__)
foreach ($fqdn in $fqdns) {
    $resolvedIp = ''
    $dnsMethod = ''
    foreach ($dnsServer in $dnsServers) {
        try {
            $nrOutput = nameresolver $fqdn $dnsServer 2>$null
            if ($nrOutput) {
                $ips = ($nrOutput -split "`n" | Where-Object { $_ -notmatch 'Server:' -and $_ -match '\s*\d{1,3}(\.\d{1,3}){3}\s*$' } | ForEach-Object { $_.Trim() }) -replace 'Addresses:\s*', ''
                $ips = @($ips | Where-Object { $_ })
                if ($ips.Count -gt 0) {
                    $resolvedIp = $ips[0]
                    $dnsMethod = "nameresolver($dnsServer)"
                    break
                }
            }
        } catch {}
    }
    if (-not $resolvedIp) {
        try {
            $addr = [System.Net.Dns]::GetHostAddresses($fqdn) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
            if ($addr) {
                $resolvedIp = $addr.IPAddressToString
                $dnsMethod = 'dotnet'
            }
        } catch {}
    }
    $tcpOk = $false
    $tcpMethod = ''
    if ($resolvedIp) {
        $port = $ports[$fqdn]
        try {
            $tpOutput = tcpping "$($resolvedIp):$port" 2>$null
            if ($tpOutput -match 'Connected to') {
                $tcpOk = $true
                $tcpMethod = 'tcpping'
            }
        } catch {}
        if (-not $tcpMethod) {
            try {
                $client = New-Object System.Net.Sockets.TcpClient
                $asyncResult = $client.BeginConnect($resolvedIp, [int]$port, $null, $null)
                if ($asyncResult.AsyncWaitHandle.WaitOne(10000)) {
                    $client.EndConnect($asyncResult)
                    $tcpOk = $client.Connected
                }
                $client.Close()
                $tcpMethod = 'tcpclient'
            } catch { $tcpMethod = 'tcpclient' }
        }
    }
    $status = if ($tcpOk) { 'OK' } else { 'FAIL' }
    Write-Output ("$fqdn|$resolvedIp|$status|$dnsMethod|$tcpMethod")
}
'@
    $RemoteScript = $RemoteScriptTemplate.Replace('__FQDNS__', $FqdnList).Replace('__PORTS__', $PortMap).Replace('__DNSSERVERS__', $DnsServerList)

    # Exceptions from Invoke-NmeKuduCommand propagate to the caller - that is what lets the caller
    # tell "the probe ran and found a problem" (returned results, some failing) apart from "the probe
    # could not run at all" (an exception here), which are handled very differently by the gate below.
    $Output = Invoke-NmeKuduCommand -ScmHost $ScmHost -ScriptText $RemoteScript
    $Lines = @()
    if ($Output) {
        $Lines = @($Output -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '\|' })
    }

    $Results = @()
    foreach ($t in $Target) {
        $Line = $Lines | Where-Object { ($_ -split '\|')[0] -eq $t.Fqdn } | Select-Object -First 1
        if ($Line) {
            $Parts = $Line -split '\|'
            $ResolvedIp = $Parts[1]
            $TcpOk = ($Parts[2] -eq 'OK')
            $DnsMethod = $Parts[3]
            $TcpMethod = $Parts[4]
        }
        else {
            # No line came back for this target at all (e.g. the remote script errored before it got
            # to this target). Treat exactly like an empty resolution - it fails Pass below.
            $ResolvedIp = ''
            $TcpOk = $false
            $DnsMethod = ''
            $TcpMethod = ''
        }
        # Pass requires BOTH: the resolved IP is non-empty and is one of the private endpoint's
        # private IPs, AND the TCP connect succeeded. The IP check is not optional and must not be
        # dropped: at the point this probe runs, public network access has not yet been disabled, so a
        # target whose DNS still returns its PUBLIC IP would happily pass a TCP-443 connect today,
        # while being exactly the misconfiguration that causes the outage a minute from now, once
        # public access actually is disabled and DNS still points at the public endpoint.
        $Pass = [bool]($ResolvedIp -and (@($t.ExpectedIp) -contains $ResolvedIp) -and $TcpOk)
        $Results += [pscustomobject]@{
            Name       = $t.Name
            Fqdn       = $t.Fqdn
            Port       = $t.Port
            ExpectedIp = $t.ExpectedIp
            ResolvedIp = $ResolvedIp
            TcpOk      = $TcpOk
            DnsMethod  = $DnsMethod
            TcpMethod  = $TcpMethod
            Pass       = $Pass
        }
    }
    return $Results
}

function Get-NmeConnectivityExpectedIps {
    # CustomDnsConfigs is NOT a reliable source for a private endpoint's actual private IP - live
    # testing (T01, P1-16) found it persistently empty (not just briefly, immediately after creation:
    # still empty when re-checked several minutes later, well past any DNS-propagation window) on
    # every endpoint in this deployment, key vault and sql alike, despite each having a fully correct
    # private-dns-zone-group and a real A record already resolving to the right address. Azure does
    # not populate this field for every private endpoint/resource-type combination - it is informational
    # metadata about the DNS integration Azure itself set up, not a guaranteed property of the endpoint.
    # The one value that is always present and authoritative once the endpoint exists is the private IP
    # on its own network interface's IP configuration - fetched here as the fallback, and used first if
    # CustomDnsConfigs is empty, since empty turned out to be the common case rather than the exception.
    param(
        [Parameter(Mandatory=$true)]$PrivateEndpoints,
        [Parameter(Mandatory=$true)][string]$PrivateLinkServiceId
    )
    $MatchedEndpoint = $PrivateEndpoints | Where-Object { $_.PrivateLinkServiceConnections.PrivateLinkServiceId -eq $PrivateLinkServiceId } | Select-Object -First 1
    if (-not $MatchedEndpoint) { return @() }
    $Ips = @($MatchedEndpoint.CustomDnsConfigs.IpAddresses | Where-Object { $_ })
    if ($Ips.Count -gt 0) { return $Ips }

    $NicIps = @()
    foreach ($NicRef in $MatchedEndpoint.NetworkInterfaces) {
        try {
            $Nic = Get-AzNetworkInterface -ResourceId $NicRef.Id -ErrorAction Stop
            $NicIps += @($Nic.IpConfigurations | ForEach-Object { $_.PrivateIpAddress } | Where-Object { $_ })
        }
        catch {
            Write-Verbose "Get-NmeConnectivityExpectedIps: could not read the network interface for private endpoint '$($MatchedEndpoint.Name)' ($($_.Exception.Message)); falling back to no expected IP for this target."
        }
    }
    return @($NicIps | Where-Object { $_ })
}

#### main script ####

# check to see if NMW app already has vnet integration enabled

# Get all existing private endpoints. This is looked up subscription-wide rather than in $NmeRg
# alone: every "does an endpoint already exist for this resource" check below matches on
# PrivateLinkServiceId, which is unique per target resource, so a wider search cannot produce a
# false match - but a narrower one misses an endpoint a customer created in another resource group
# and this script then creates a duplicate. Endpoints this script creates still go in $NmeRg.
# If the subscription-wide list is denied by RBAC, fall back to $NmeRg and say so.
try {
    $ExistingPrivateEndpoints = Get-AzPrivateEndpoint -ErrorAction Stop
}
catch {
    Write-Warning "Unable to list private endpoints across the subscription ($($_.Exception.Message)). Falling back to resource group '$NmeRg' only - if a private endpoint for one of these resources exists in another resource group, this script will not see it and will create a duplicate."
    $ExistingPrivateEndpoints = Get-AzPrivateEndpoint -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue
}

# Check if vnet created. Nerdio Manager's own resource group is searched first, deliberately: a
# subscription-wide lookup by name alone will happily bind an unrelated VNet that merely shares the
# name, in a resource group belonging to a different deployment or a different team. That is not
# hypothetical - it was found live on a shared test subscription, where an unrelated
# 'nmw-private-vnet' in another resource group (created by someone else running this same script with
# its default parameters, so it even had the same address range) was picked up by a greenfield run.
# Only the region check below stopped it; had that VNet been in NME's region, this script would have
# created every private endpoint, linked every DNS zone, and VNet-integrated Nerdio Manager into a
# stranger's network. The >1-match Throw is no protection against it, because a single match in the
# wrong resource group looks unambiguous.
$VNet = Get-AzVirtualNetwork -Name $PrivateLinkVnetName -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue
if (-not $VNet) {
    # Not in NME's resource group. An existing VNet elsewhere is explicitly supported (see the
    # PrivateLinkVnetName parameter description), so fall back to a subscription-wide search - but
    # say plainly which resource group the VNet came from, since that is the one case where this
    # script operates on a network it does not own.
    $VNet = Get-AzVirtualNetwork -Name $PrivateLinkVnetName -ErrorAction SilentlyContinue
    if ($VNet -and @($VNet).Count -eq 1) {
        Write-Warning "VNet '$PrivateLinkVnetName' was not found in Nerdio Manager's resource group '$NmeRg', but a VNet with that name exists in resource group '$($VNet.ResourceGroupName)'. This run will add private endpoints, DNS zone links and service endpoints to that VNet, and will VNet-integrate Nerdio Manager into it. If that is not the VNet you intended, stop and re-run with a VNet name that is unique to this deployment - a same-named VNet belonging to another deployment or team would otherwise be modified."
    }
}
if ($VNet) {
    if (@($VNet).Count -gt 1) {
        Throw "Found more than one VNet with name $PrivateLinkVnetName. Please remove any VNets no longer in use or use a unique name."
    }
    Write-Output ("VNet {0} found in resource group {1}." -f $VNet.Name, $VNet.ResourceGroupName)

    # Region check runs here, before any subnet is added below, so a wrong-region VNet is rejected
    # without this script having modified the customer's existing VNet at all. App Service regional
    # VNet integration requires the VNet to be in the same region as the app service plan, so a
    # mismatch can never succeed - confirmed live (T09), where the pre-fix behavior warned and
    # carried on to create 16 private endpoints and 6 DNS zones before ARM rejected the integration
    # with "Location <x> of virtual network <y> does not match requested location <z>". The
    # VNet-creation branch below needs no equivalent check: it creates the VNet in $NmeRegion.
    if ($VNet.Location -ne $NmeRegion) {
        throw "The VNet '$PrivateLinkVnetName' is in region '$($VNet.Location)' but Nerdio Manager is deployed in '$NmeRegion'. App Service regional VNet integration requires the VNet to be in the same region as the app service plan, so this run cannot succeed. Use a VNet in the '$NmeRegion' region."
    }

    $vnetUpdated = $false
    # Check if subnet created
    $PrivateEndpointSubnet = Get-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -VirtualNetwork $VNet -ErrorAction SilentlyContinue
    if ($PrivateEndpointSubnet) {
        Write-Output ("Subnet {0} found in VNet {1}." -f $PrivateEndpointSubnet.Name, $VNet.Name)
        # A subnet delegated to another service cannot hold private endpoints, and this script has no
        # safe way to remove someone else's delegation. Fail here rather than at the first
        # New-AzPrivateEndpoint call, which is after the DNS zone region has already run.
        $PeSubnetDelegations = @($PrivateEndpointSubnet.Delegations | Where-Object { $_.ServiceName })
        if ($PeSubnetDelegations.Count) {
            throw "The private endpoint subnet '$PrivateEndpointSubnetName' in VNet '$PrivateLinkVnetName' is delegated to $($PeSubnetDelegations.ServiceName -join ', '). A delegated subnet cannot host private endpoints. Use a subnet with no delegation for PrivateEndpointSubnetName, or remove the delegation, and re-run."
        }
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

        # Both of these conditions make the VNet-integration region below impossible, and both are
        # knowable now - before the DNS zone and private endpoint regions do their work. The
        # delegation case would otherwise surface as a failure on Add-AzDelegation (a subnet takes
        # only one delegation); the size case as an ARM rejection when enabling integration.
        $AppSubnetDelegations = @($AppServiceSubnet.Delegations | Where-Object { $_.ServiceName -and $_.ServiceName -ne 'Microsoft.Web/serverFarms' })
        if ($AppSubnetDelegations.Count) {
            throw "The app service subnet '$AppServiceSubnetName' in VNet '$PrivateLinkVnetName' is delegated to $($AppSubnetDelegations.ServiceName -join ', '), but App Service regional VNet integration requires it to be delegated to Microsoft.Web/serverFarms. A subnet supports only one delegation, so this script cannot add the required one. Use a different subnet for AppServiceSubnetName, or remove the conflicting delegation, and re-run."
        }
        $AppSubnetPrivateEndpoints = @($AppServiceSubnet.PrivateEndpoints | Where-Object { $_ })
        if ($AppSubnetPrivateEndpoints.Count) {
            throw "The app service subnet '$AppServiceSubnetName' in VNet '$PrivateLinkVnetName' contains private endpoints. App Service regional VNet integration requires a subnet delegated to Microsoft.Web/serverFarms, and a delegated subnet cannot also hold private endpoints. Use a dedicated, empty subnet for AppServiceSubnetName - it must be different from PrivateEndpointSubnetName - and re-run."
        }
        # Azure requires at least a /28 for regional VNet integration. Below that, integration is
        # rejected outright; between /28 and /26 it works but leaves little headroom, which matters
        # because the range cannot be widened later without removing every app's integration first
        # (see the AppServiceSubnetRange parameter description).
        # AddressPrefix is a List[string] on current Az.Network but has been a plain string on older
        # versions, where indexing [0] would return the first character instead of the first prefix.
        # Select-Object -First 1 gives the first prefix in either shape.
        $AppSubnetPrefix = $AppServiceSubnet.AddressPrefix | Select-Object -First 1
        $AppSubnetPrefixLength = [int](($AppSubnetPrefix -split '/')[1])
        if ($AppSubnetPrefixLength -gt 28) {
            throw "The app service subnet '$AppServiceSubnetName' in VNet '$PrivateLinkVnetName' is a /$AppSubnetPrefixLength. App Service regional VNet integration requires a /28 or larger, and a /26 is the Microsoft recommendation for the up-to-four Nerdio Manager apps that integrate into this subnet. Recreate the subnet with a larger range and re-run."
        }
        elseif ($AppSubnetPrefixLength -gt 26) {
            Write-Warning "The app service subnet '$AppServiceSubnetName' is a /$AppSubnetPrefixLength. This meets the /28 minimum for App Service regional VNet integration but is below the recommended /26 - scale-out and in-place plan changes each temporarily double IP consumption, and up to four Nerdio Manager apps integrate into this one subnet. The range cannot be widened by re-running this script; the subnet would have to be recreated, which means removing the VNet integration from every app first."
        }
    } else {
        Write-Output "Creating app service subnet"
        $AppServiceSubnet = New-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -AddressPrefix $AppServiceSubnetRange 
        $VNet | Add-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -AddressPrefix $AppServiceSubnetRange
        $vnetUpdated = $true
    }
 
    If ($vnetUpdated){
        # Capture the result rather than discarding it: Set-AzVirtualNetwork returns the updated VNet,
        # and keeping it means the rest of the script can work from one object instead of re-fetching.
        $VNet = $VNet | Set-AzVirtualNetwork
    }
 
} else {
    Write-Output "Creating VNet and subnets"
    $PrivateEndpointSubnet = New-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -AddressPrefix $PrivateEndpointSubnetRange -PrivateEndpointNetworkPoliciesFlag Disabled 
    $AppServiceSubnet = New-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -AddressPrefix $AppServiceSubnetRange 
    $VNet = New-AzVirtualNetwork -Name $PrivateLinkVnetName -ResourceGroupName $NmeRg -Location $NmeRegion -AddressPrefix $VnetAddressRange -Subnet $PrivateEndpointSubnet,$AppServiceSubnet
}

# Private endpoints must be created in the same region as the VNet holding their subnet, which is not
# necessarily the region NME is deployed in when an existing VNet is supplied. The mismatch case is
# rejected in the existing-VNet branch above, before that VNet is touched; this just captures the
# location for the New-AzPrivateEndpoint calls.
$VnetLocation = $VNet.Location
# Capture the VNet's resource group so later lookups are unambiguous - an existing VNet may live in
# a different resource group than NME, and fetching by name alone can match VNets in other groups.
$VnetRg = $VNet.ResourceGroupName

# Resolved once here, after $VNet exists: the "exclude the private endpoint VNet itself" filter
# below needs $VNet.id, and this used to run before $VNet was assigned, so the filter silently
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

function Get-NmeLinkedNetworkSubnetIds {
    # Restricted mode allows the cssa storage account's public endpoint only from subnets belonging
    # to VNets NME considers linked (tagged <prefix>_OBJECT_TYPE = LINKED_NETWORK), across every
    # subscription this service principal can read - not just the one NME runs in. Azure storage
    # VirtualNetworkRule entries are scoped to a specific subnet, and only take effect if that
    # subnet has the Microsoft.Storage service endpoint enabled; this function does not enable it on
    # subnets it doesn't own (see the P2-10 precedent for why), it only reports and skips subnets
    # that lack it.
    param(
        [Parameter(Mandatory=$true)][string]$Prefix
    )
    $SubnetIds = @()
    $OriginalContext = Get-AzContext
    try {
        $Subscriptions = Get-AzSubscription -ErrorAction Stop
        foreach ($Subscription in $Subscriptions) {
            try {
                Set-AzContext -SubscriptionId $Subscription.Id -ErrorAction Stop | Out-Null
            }
            catch {
                Write-Warning "Skipping subscription '$($Subscription.Name)' ($($Subscription.Id)) while looking for LINKED_NETWORK VNets: could not set context. $($_.Exception.Message)"
                continue
            }
            $LinkedVnets = Get-AzVirtualNetwork -ErrorAction SilentlyContinue |
                Where-Object { $null -ne $_.Tag } |
                Where-Object { $_.Tag["$Prefix`_OBJECT_TYPE"] -eq 'LINKED_NETWORK' }
            foreach ($LinkedVnet in $LinkedVnets) {
                # Both service endpoint values are accepted for a storage VirtualNetworkRule:
                # 'Microsoft.Storage' is the regional endpoint, 'Microsoft.Storage.Global' the
                # cross-region one (strictly broader - it reaches storage accounts in any region,
                # which is exactly the case a linked AVD VNet in another region needs). Matching only
                # the regional value would skip a subnet that is in fact correctly configured, warn
                # that it cannot be allowed through the firewall, and then cut off its access when
                # default-deny is applied. Seen live on this lab's own shared VNet.
                $StorageServiceEndpointNames = @('Microsoft.Storage', 'Microsoft.Storage.Global')
                $EnabledSubnets = @($LinkedVnet.Subnets | Where-Object {
                    $SubnetServices = @($_.ServiceEndpoints.Service)
                    @($SubnetServices | Where-Object { $StorageServiceEndpointNames -contains $_ }).Count -gt 0
                })
                if (-not $EnabledSubnets.Count) {
                    Write-Warning "LINKED_NETWORK VNet '$($LinkedVnet.Name)' (subscription $($Subscription.Id)) has no subnet with the Microsoft.Storage or Microsoft.Storage.Global service endpoint enabled, so CssaStorageAccount=Restricted cannot allow it through the storage firewall. Enable Microsoft.Storage on the subnet that needs access and re-run."
                    continue
                }
                $SubnetIds += $EnabledSubnets | Select-Object -ExpandProperty Id
            }
        }
    }
    finally {
        # Restore the caller's subscription context unconditionally - everything after this call
        # in the script assumes it is running against the NME subscription.
        Set-AzContext -Context $OriginalContext | Out-Null
    }
    return @($SubnetIds | Select-Object -Unique)
}

#region create DNS zones and links
if (-not $SkipDNS) {
    # Create and link private dns zone for key vault
    if ($existingDNSZonesSubId) {
        Write-Output "Setting context to subscription $existingDNSZonesSubId to create network links in DNS zones"
        $context = Set-AzContext -Subscription $existingDNSZonesSubId
    }
    if ($KeyVaultDnsZone) { 
        Write-Output "Found Private DNS Zone for Key Vault"
        #check for linked zone
        $KeyVaultZoneLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $KeyVaultDnsZoneName -ErrorAction SilentlyContinue
        if ($KeyVaultZoneLink.VirtualNetworkId -contains $VNet.id) {
            Write-Output "Private DNS Zone for Key Vault already linked to vnet"
        }
        else {
            Write-Output "Linking Private DNS Zone for Key Vault to vnet"
            $KeyVaultZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $KeyVaultDnsZoneName -Name $KeyVaultZoneLinkName -VirtualNetworkId $VNet.Id
        }
    }
    else {
        Write-Output "Creating Private DNS Zones and VNet link for Key Vault"
        $KeyVaultDnsZone = New-AzPrivateDnsZone -ResourceGroupName $NmeRg -Name $KeyVaultDnsZoneName
        $KeyVaultZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NmeRg -ZoneName $KeyVaultDnsZoneName -Name $KeyVaultZoneLinkName -VirtualNetworkId $VNet.Id
    }

    # Create and link private dns zone for sql 
    if ($SqlDnsZone) {
        Write-Output "Found Private DNS Zone for SQL"
        # check for linked zone
        $SqlZoneLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $SqlDnsZoneName -ErrorAction SilentlyContinue
        if ($SqlZoneLink.VirtualNetworkId -contains $VNet.id) {
            Write-Output "Private DNS Zone for SQL already linked to vnet"
        }
        else {
            Write-Output "Linking Private DNS Zone for SQL to vnet"
            $SqlZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $SqlDnsZoneName -Name $SqlZoneLinkName -VirtualNetworkId $VNet.Id
        }
    }
    else {
        Write-Output "Creating Private DNS Zones and VNet link for SQL"
        $SqlDnsZone = New-AzPrivateDnsZone -ResourceGroupName $NmeRg -Name $SqlDnsZoneName
        $SqlZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NmeRg -ZoneName $SqlDnsZoneName -Name $SqlZoneLinkName -VirtualNetworkId $VNet.Id
    }

    if ($StorageDnsZone) {
        Write-Output "Found Private DNS Zone for Storage"
        # check for linked zone
        $StorageZoneLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $StorageDnsZoneName -ErrorAction SilentlyContinue
        if ($StorageZoneLink.VirtualNetworkId -contains $VNet.id) {
            Write-Output "Private DNS Zone for Storage already linked to vnet"
        }
        else {
            Write-Output "Linking Private DNS Zone for Storage to vnet"
            $StorageZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $StorageDnsZoneName -Name $BlobZoneLinkName -VirtualNetworkId $VNet.Id
        }
    }
    else {
        Write-Output "Creating Private DNS Zones and VNet link for Storage"
        $StorageDnsZone = New-AzPrivateDnsZone -ResourceGroupName $NmeRg -Name $StorageDnsZoneName
        $StorageZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NmeRg -ZoneName $StorageDnsZoneName -Name $BlobZoneLinkName -VirtualNetworkId $VNet.Id
    }

    # Real Time Insights storage account uses the table storage API, so it needs its own private DNS zone
    if ($NmeRtiStorageAccountName) {
        if ($TableDnsZone) {
            Write-Output "Found Private DNS Zone for Table Storage"
            # check for linked zone
            $TableZoneLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $TableDnsZoneName -ErrorAction SilentlyContinue
            if ($TableZoneLink.VirtualNetworkId -contains $VNet.id) {
                Write-Output "Private DNS Zone for Table Storage already linked to vnet"
            }
            else {
                Write-Output "Linking Private DNS Zone for Table Storage to vnet"
                $TableZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $TableDnsZoneName -Name $RtiTableStoragePrivateDnsZoneLinkName -VirtualNetworkId $VNet.Id
            }
        }
        else {
            Write-Output "Creating Private DNS Zones and VNet link for Table Storage"
            $TableDnsZone = New-AzPrivateDnsZone -ResourceGroupName $NmeRg -Name $TableDnsZoneName
            $TableZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NmeRg -ZoneName $TableDnsZoneName -Name $RtiTableStoragePrivateDnsZoneLinkName -VirtualNetworkId $VNet.Id
        }
    }

    # Create and link private dns zone for automation account
    if ($AutomationDnsZone) {
        Write-Output "Found Private DNS Zone for Automation"
        # check for linked zone
        $AutomationZoneLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $AutomationDnsZoneName -ErrorAction SilentlyContinue
        if ($AutomationZoneLink.VirtualNetworkId -contains $VNet.id) {
            Write-Output "Private DNS Zone for Automation already linked to vnet"
        }
        else {
            Write-Output "Linking Private DNS Zone for Automation to VNet"
            $AutomationZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $AutomationDnsZoneName -Name $AutomationZoneLinkName -VirtualNetworkId $VNet.Id
        }
    }
    else {
        Write-Output "Creating Private DNS Zones and VNet link for Automation"
        $AutomationDnsZone = New-AzPrivateDnsZone -ResourceGroupName $NmeRg -Name $AutomationDnsZoneName
        $AutomationZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NmeRg -ZoneName $AutomationDnsZoneName -Name $AutomationZoneLinkName -VirtualNetworkId $VNet.Id
    }

    # Create and link private dns zone for app service
    if ($AppServiceDnsZone) {
        Write-Output "Found Private DNS Zone for App Service"
        # check for linked zone
        $AppServiceZoneLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $AppServiceDnsZoneName -ErrorAction SilentlyContinue
        if ($AppServiceZoneLink.VirtualNetworkId -contains $VNet.id) {
            Write-Output "Private DNS Zone for App Service already linked to vnet"
        }
        else {
            Write-Output "Linking Private DNS Zone for App Service to vnet"
            $AppServiceZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $DnsRg -ZoneName $AppServiceDnsZoneName -Name $AppServiceZoneLinkName -VirtualNetworkId $VNet.Id
        }
    }
    else {
        Write-Output "Creating Private DNS Zones for App Service"
        $AppServiceDnsZone = New-AzPrivateDnsZone -ResourceGroupName $NmeRg -Name $AppServiceDnsZoneName
        $AppServiceZoneLink = New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $NmeRg -ZoneName $AppServiceDnsZoneName -Name $AppServiceZoneLinkName -VirtualNetworkId $VNet.Id
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
        # The app service private DNS zone is shared by all four web apps (NME, CCL, Intune Insights and RTI) -
        # they all resolve the same *.azurewebsites.net/.us hostname pattern through this one zone. So a peer
        # VNet needs this link whenever ANY of those app services is made private, not only the primary one.
        # Without this, MakeRtiAppServicePrivate = true with MakeAppServicePrivate = false would lock down RTI
        # while leaving peered VNets (e.g. an AVD VNet) unable to resolve its FQDN - the exact silent-failure
        # scenario the MakeRtiAppServicePrivate parameter description warns about, for the one population that
        # was supposed to be recoverable by peering.
        if ($MakeAppServicePrivate -or $MakeRtiAppServicePrivate){
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

# Storage sub-resource -> resolved private DNS zone object, built here rather than immediately after
# the zone objects are first resolved: on a greenfield run $StorageDnsZone/$TableDnsZone are $null at
# that point and only get assigned real zone objects inside the "create DNS zones and links" region
# above (New-AzPrivateDnsZone). A hashtable literal copies the variable's value at construction time,
# not a live reference to the variable, so building this map before that region ran was capturing the
# pre-creation $null and handing New-NmeStoragePrivateEndpoint a zone with no ResourceId - which is
# exactly the "Cannot validate argument on parameter 'PrivateDnsZoneId'" failure this caused on a
# real greenfield run. Must stay after the DNS zone creation region. $TableDnsZone is only resolved/
# created when $NmeRtiStorageAccountName is set, so it may still be $null here - that matches today's
# behavior, since nothing but the RTI account uses the table zone.
$StorageSubresourceDnsZones = @{
    blob  = $StorageDnsZone
    table = $TableDnsZone
}

#region create private endpoints
# $VNet is already current here - nothing between its creation/resolution above and this point
# modifies it - so it is not re-fetched. Get-AzVirtualNetworkSubnetConfig reads the in-memory object
# and costs no API call.
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
if (-not $SkipDNS) {
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
    if (-not $SkipDNS) {
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
    if (-not $SkipDNS) {
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
if (-not $SkipDNS) {
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
    if (-not $SkipDNS) {
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
if (-not $SkipDNS) {
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
    if (-not $SkipDNS) {
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

    if ($CssaStorageAccount -ne 'Public') {
        # Both Private and Restricted need the private endpoint - only Public skips it.
        # Get scripted actions storage account (resolved in Set-NmeVars via tag, then name pattern, then the NMW_RESOURCE fallback tag)
        $ScriptedActionsStorageAccount = Get-AzStorageAccount -ResourceGroupName $NmeRg -Name $NmeScriptedActionsStorageAccountName -ErrorAction SilentlyContinue
        # throw error if no scripted actions storage account found
        if (-not $ScriptedActionsStorageAccount) {
            throw "No scripted actions storage account found in resource group $NmeRg. Please add the tag '$NmeResourceTagName' with value 'CUSTOM_SCRIPTS_STORAGE_ACCOUNT' to the scripted actions storage account used by Nerdio Manager and rerun this script."
        }
        New-NmeStoragePrivateEndpoint -StorageAccount $ScriptedActionsStorageAccount -Subresource blob `
            -PrivateEndpointName $ScriptedActionsStoragePrivateEndpointName -ServiceConnectionName $SaStorageServiceConnectionName `
            -DnsZoneGroupName $SaStoragePrivateDnsZoneGroupName -DisplayName 'scripted actions' | Out-Null
    }
}

if ($NmeCclStorageAccountName) {
    # Get ccl storage account
    $NmeCclStorageAccount = Get-AzStorageAccount -ResourceGroupName $NmeRg -Name $NmeCclStorageAccountName
    New-NmeStoragePrivateEndpoint -StorageAccount $NmeCclStorageAccount -Subresource blob `
        -PrivateEndpointName $CclStoragePrivateEndpointName -ServiceConnectionName $CclStorageServiceConnectionName `
        -DnsZoneGroupName $CclStoragePrivateDnsZoneGroupName -DisplayName 'CCL' | Out-Null
}

if ($NmeDpsStorageAccountName) {
    # Get dps storage account
    $NmeDpsStorageAccount = Get-AzStorageAccount -ResourceGroupName $NmeRg -Name $NmeDpsStorageAccountName
    New-NmeStoragePrivateEndpoint -StorageAccount $NmeDpsStorageAccount -Subresource blob `
        -PrivateEndpointName $DpsStoragePrivateEndpointName -ServiceConnectionName $DpsStorageServiceConnectionName `
        -DnsZoneGroupName $DpsStoragePrivateDnsZoneGroupName -DisplayName 'DPS' | Out-Null
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
    $AppServiceServiceConnection = New-AzPrivateLinkServiceConnection -Name $AppServiceServiceConnectionName -PrivateLinkServiceId $AppServiceResourceId -GroupId sites 
    $AppServicePrivateEndpoint = New-AzPrivateEndpoint -Name "$AppServicePrivateEndpointName" -ResourceGroupName $NmeRg -Location $VnetLocation -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $AppServiceServiceConnection 
}
# check if app service dns zone group created
if (-not $SkipDNS) {
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
        $CclAppServiceServiceConnection = New-AzPrivateLinkServiceConnection -Name $CclAppServiceServiceConnectionName -PrivateLinkServiceId $CclAppServiceResourceId -GroupId sites 
        $CclAppServicePrivateEndpoint = New-AzPrivateEndpoint -Name "$CclAppServicePrivateEndpointName" -ResourceGroupName $NmeRg -Location $VnetLocation -Subnet $PrivateEndpointSubnet -PrivateLinkServiceConnection $CclAppServiceServiceConnection 
    }
    # check if ccl app service dns zone group created
    if (-not $SkipDNS) {
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
    if (-not $SkipDNS) {
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
    if (-not $SkipDNS) {
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
    if (-not $SkipDNS) {
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
    New-NmeStoragePrivateEndpoint -StorageAccount $NmeRtiStorageAccount -Subresource table `
        -PrivateEndpointName $RtiStoragePrivateEndpointName -ServiceConnectionName $RtiStorageServiceConnectionName `
        -DnsZoneGroupName $RtiStorageDnsZoneGroupName -DisplayName 'RTI' | Out-Null
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
    if (-not $SkipDNS) {
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
    foreach ($id in $VnetIds) {
        Write-Output "Peering with vnet $id"
        # Deliberate refresh on every iteration: Add-AzVirtualNetworkPeering below mutates the VNet,
        # so the copy from the previous iteration is stale and its etag would be rejected.
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
            $InboundPeering = Add-AzVirtualNetworkPeering -Name "$($PeerVnet.name)-$PrivateLinkVnetName" -VirtualNetwork $PeerVnet -RemoteVirtualNetworkId $VNet.id 
        }
        # check if outbound peering exists
        $OutboundPeering = Get-AzVirtualNetworkPeering -Name "$PrivateLinkVnetName-$($PeerVnet.name)" -VirtualNetworkName $VNet.Name -ResourceGroupName $VNet.ResourceGroupName -ErrorAction SilentlyContinue
        if ($OutboundPeering) {
            Write-Output "Outbound peering exists"
        }
        else {
            Write-Output "Creating outbound peering"
            $OutboundPeering = Add-AzVirtualNetworkPeering -Name "$PrivateLinkVnetName-$($PeerVnet.name)" -VirtualNetwork $VNet -RemoteVirtualNetworkId $id
        }
    }
}
#endregion


#region app service vnet integration

Write-Output "Add VNet service endpoints"
# Deliberate refresh: the peering region above mutates the VNet when PeerVnetIds is supplied.
$VNet = Get-AzVirtualNetwork -Name $PrivateLinkVnetName -ResourceGroupName $VnetRg
$PrivateEndpointSubnet = Get-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -VirtualNetwork $VNet
$AppServiceSubnet = Get-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -VirtualNetwork $VNet 

# Why service endpoints exist here at all, alongside private endpoints. Traffic that arrives over a
# private endpoint is not evaluated against VNet or service-endpoint rules, and once
# PublicNetworkAccess is Disabled those rules are inert regardless - so in the steady state this is
# redundant with the private-endpoint model. They are kept deliberately, as a documented fallback for
# the window before the make-private region runs (and for a deployment that stops short of it, for
# example one that leaves CssaStorageAccount at Public), during which the app service can still reach
# key vault, sql and storage over the service endpoint. Mixing the two models is what makes this region
# hard to read; this comment is the record of that being a decision rather than an oversight.
$ServiceEndpoints = @('Microsoft.KeyVault', 'Microsoft.Sql', 'Microsoft.Web')
if ($CssaStorageAccount -ne 'Public') {
    # Both Private and Restricted need this - only Public skips it.
    $ServiceEndpoints += 'Microsoft.Storage'
}
# Union with what is already on the subnet so a previous run's service endpoints (for example
# Microsoft.Storage from a run with CssaStorageAccount not Public) are not removed.
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
    if ($PrivateEndpointSubnet.NetworkSecurityGroup.Id) {
        Write-Warning "Enabling privateEndpointNetworkPolicies on subnet '$($PrivateEndpointSubnet.Name)' starts enforcing network security group '$($PrivateEndpointSubnet.NetworkSecurityGroup.Id.Split('/')[-1])' rules against the private endpoints in this subnet."
    }
    try {
        $VNet = Set-NmeSubnetConfig -VirtualNetwork $VNet -SubnetName $PrivateEndpointSubnetName -ServiceEndpoint $ServiceEndpoints -PrivateEndpointNetworkPoliciesFlag Enabled
    }
    catch {
        # sometimes can't enable network policies on subnet with private endpoints, e.g. in gov cloud
        Write-Output "Enabling network policies failed, setting to disabled"
        $VNet = Set-NmeSubnetConfig -VirtualNetwork $VNet -SubnetName $PrivateEndpointSubnetName -ServiceEndpoint $ServiceEndpoints -PrivateEndpointNetworkPoliciesFlag Disabled
    }
}


# Set-NmeSubnetConfig returns the updated VNet, so $VNet is current here without a re-fetch.
$AppServiceSubnet = Get-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -VirtualNetwork $VNet

# Check if subnet delegation created
$AppSubnetDelegation = Get-AzDelegation -Subnet $AppServiceSubnet -ErrorAction SilentlyContinue
if ($AppSubnetDelegation.ServiceName -eq 'Microsoft.Web/serverFarms') {
    Write-Output "App service subnet delegation already created"
} 
else {
    Write-Output "Delegate app service subnet to webfarms"
    $AppServiceSubnet | Add-AzDelegation -Name $WebAppSubnetDelegationName -ServiceName "Microsoft.Web/serverFarms" | Out-Null
    $VNet = Set-AzVirtualNetwork -VirtualNetwork $VNet
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

#region private DNS and network preflight checks
# The NSG/route table checks further down only report - they never block, throw or alter control
# flow. The connectivity gate immediately below is the exception: it can Throw and stop the script
# before the make-private region runs. Both run after private endpoints and DNS zone groups have been
# created but before the make-private region below disables public access on the key vault(s) and sql
# server(s), which is the point after which recovery requires the Azure Portal rather than another run
# of this script.

# --- Real connectivity probe from inside the VNet-integrated app service worker -------------------
# Test-NmePrivateDnsResolution (the fallback used further below) proves the Azure private DNS zone has
# an A record for a resource. That proves the private endpoint's DNS zone group did its job, but
# nothing about what the Nerdio Manager app service actually resolves and can reach - it says nothing
# about whether the zone is linked to the right VNet, whether the worker is actually consulting it, or
# about routing and NSGs. It is also useless when SkipDNS is true, since a customer running their own
# DNS may have no Azure private DNS zone to check at all. So this probe, not the zone-record check, is
# what gates the make-private region: if Nerdio Manager cannot reach its key vault, sql server or DPS
# storage account, the app fails to load with a 500.30 error, so disabling public access in that state
# is a guaranteed outage.
#
# Exactly three targets are probed - nothing else - matching what the app needs merely to start:
#   1. the Nerdio Manager key vault, TCP 443
#   2. the primary sql server, TCP 1433
#   3. the DPS storage account (blob), TCP 443, only when $NmeDpsStorageAccountName is set
$ConnectivityTargets = @()
$ConnectivityTargets += [pscustomobject]@{
    Name       = 'Nerdio Manager key vault'
    # Read the FQDN off the resource rather than composing it from the vault name and a hardcoded
    # suffix - composing breaks in sovereign clouds such as US Gov, where the suffix differs.
    Fqdn       = ([uri]$NmeKeyVault.VaultUri).Host
    Port       = 443
    ExpectedIp = @()
}
if (-not $SqlServer) {
    $SqlServer = Get-AzSqlServer -ResourceGroupName $NmeRg -ServerName $NmeSqlServerName
}
$ConnectivityTargets += [pscustomobject]@{
    Name       = 'primary sql server'
    Fqdn       = $SqlServer.FullyQualifiedDomainName
    Port       = 1433
    ExpectedIp = @()
}
if ($NmeDpsStorageAccountName) {
    if (-not $NmeDpsStorageAccount) {
        $NmeDpsStorageAccount = Get-AzStorageAccount -ResourceGroupName $NmeRg -Name $NmeDpsStorageAccountName
    }
    $ConnectivityTargets += [pscustomobject]@{
        Name       = 'DPS storage account'
        Fqdn       = ([uri]$NmeDpsStorageAccount.PrimaryEndpoints.Blob).Host
        Port       = 443
        ExpectedIp = @()
    }
}

# Re-fetch private endpoints subscription-wide, with the same fallback-to-$NmeRg pattern used for
# $ExistingPrivateEndpoints earlier in this script, rather than reusing $KvPrivateEndpoint /
# $SqlPrivateEndpoint / the DPS storage helper's return value (which is discarded at its call site). A
# freshly created endpoint may not have CustomDnsConfigs populated yet on the object New-AzPrivateEndpoint
# returned earlier in this same run, so only a fresh Get can be trusted for the private IPs here.
try {
    $ConnectivityPrivateEndpoints = Get-AzPrivateEndpoint -ErrorAction Stop
}
catch {
    Write-Warning "Unable to list private endpoints across the subscription ($($_.Exception.Message)). Falling back to resource group '$NmeRg' only for the connectivity probe - a private endpoint in another resource group will not be matched, and its target's expected-IP list will be empty (which fails the probe for that target)."
    $ConnectivityPrivateEndpoints = Get-AzPrivateEndpoint -ResourceGroupName $NmeRg -ErrorAction SilentlyContinue
}

($ConnectivityTargets | Where-Object { $_.Name -eq 'Nerdio Manager key vault' }).ExpectedIp = Get-NmeConnectivityExpectedIps -PrivateEndpoints $ConnectivityPrivateEndpoints -PrivateLinkServiceId $NmeKeyVault.ResourceId
($ConnectivityTargets | Where-Object { $_.Name -eq 'primary sql server' }).ExpectedIp = Get-NmeConnectivityExpectedIps -PrivateEndpoints $ConnectivityPrivateEndpoints -PrivateLinkServiceId $SqlServer.ResourceId
if ($NmeDpsStorageAccountName) {
    ($ConnectivityTargets | Where-Object { $_.Name -eq 'DPS storage account' }).ExpectedIp = Get-NmeConnectivityExpectedIps -PrivateEndpoints $ConnectivityPrivateEndpoints -PrivateLinkServiceId $NmeDpsStorageAccount.Id
}

# SCM host: prefer the app's own EnabledHostNames (works in every cloud without composing anything).
# Fall back to deriving it from DefaultHostName by inserting '.scm' after the site name, e.g.
# foo.azurewebsites.net -> foo.scm.azurewebsites.net - this also works for azurewebsites.us since it
# only touches the part before the first dot.
$ScmHost = $NmeWebApp.EnabledHostNames | Where-Object { $_ -match '\.scm\.' } | Select-Object -First 1
if (-not $ScmHost) {
    $HostNameParts = $NmeWebApp.DefaultHostName.Split('.', 2)
    $ScmHost = "$($HostNameParts[0]).scm.$($HostNameParts[1])"
}

# DNS servers to query explicitly, rather than relying on whatever the worker process happens to be
# using - this is what removes the need to restart the app or retry, since nameresolver queries a
# specific server immediately without changing app config. An empty DhcpOptions.DnsServers means the
# VNet uses Azure-provided DNS: 168.63.129.16 is Azure's DNS virtual IP, and querying it directly is
# what actually consults the private DNS zones linked to this VNet.
$ConnectivityDnsServers = @($VNet.DhcpOptions.DnsServers | Where-Object { $_ })
if ($ConnectivityDnsServers.Count -eq 0) {
    $ConnectivityDnsServers = @('168.63.129.16')
}
Write-Output "Connectivity probe will query DNS server(s): $($ConnectivityDnsServers -join ', ')"

try {
    $ConnectivityResults = Test-NmeAppServiceConnectivity -ScmHost $ScmHost -DnsServer $ConnectivityDnsServers -Target $ConnectivityTargets
}
catch {
    # "Could not run the probe" is NOT a failure. Disabling public network access on the app service
    # also blocks its own SCM/Kudu endpoint, so on any deployment where MakeAppServicePrivate was set
    # by an earlier run, a later re-run of this script cannot reach Kudu at all - treating that as a
    # failure would make the script permanently un-re-runnable on exactly the deployments that took
    # its advice. Warn and proceed; only a probe that ran and reported a bad result throws.
    Write-Warning "Could not run the connectivity probe from inside the app service worker via Kudu ($($_.Exception.Message)). This is expected when the app service's public network access - and therefore its SCM endpoint - has already been disabled by an earlier run of this script. Proceeding without this check."
    $ConnectivityResults = $null
}

if ($ConnectivityResults) {
    foreach ($Result in $ConnectivityResults) {
        $ResultLine = "$($Result.Name) ($($Result.Fqdn):$($Result.Port)): resolved '$($Result.ResolvedIp)' via $($Result.DnsMethod); expected one of [$($Result.ExpectedIp -join ', ')]; TCP $(if ($Result.TcpOk) { 'connected' } else { 'failed' }) via $($Result.TcpMethod)"
        if ($Result.Pass) {
            Write-Output "PASS: $ResultLine"
        }
        else {
            Write-Warning "FAIL: $ResultLine"
        }
    }
    $FailedConnectivityTargets = @($ConnectivityResults | Where-Object { -not $_.Pass })
    if ($FailedConnectivityTargets.Count -gt 0) {
        $FailedConnectivityNames = ($FailedConnectivityTargets | ForEach-Object { $_.Name }) -join ', '
        Throw "The connectivity probe run from inside the app service worker failed for: $FailedConnectivityNames. Nerdio Manager will not load (500.30 error) if it cannot reach these resources, so no public network access has been disabled by this run - the script stopped here before the make-private region. Fix DNS resolution and/or routing/NSGs for the failed target(s) above and re-run."
    }
}
elseif (-not $SkipDNS) {
    # Fallback: the weaker DNS-zone-record check, only used when the real probe above could not run.
    Write-Output "Checking private DNS records before disabling public access (fallback check - the in-worker connectivity probe could not run)"
    $DnsCheckFailures = 0
    if ($existingDNSZonesSubId) {
        Write-Output "Setting context to subscription $existingDNSZonesSubId to check private DNS records"
        $context = Set-AzContext -Subscription $existingDNSZonesSubId
    }
    if (-not (Test-NmePrivateDnsResolution -ZoneName $KeyVaultDnsZoneName -ZoneResourceGroupName $DnsRg -RecordName $KeyVaultName -DisplayName 'Nerdio Manager key vault')) { $DnsCheckFailures++ }
    if ($NmeCclKeyVaultName) {
        if (-not (Test-NmePrivateDnsResolution -ZoneName $KeyVaultDnsZoneName -ZoneResourceGroupName $DnsRg -RecordName $NmeCclKeyVaultName -DisplayName 'CCL key vault')) { $DnsCheckFailures++ }
    }
    if ($NmeIiKeyVaultName) {
        if (-not (Test-NmePrivateDnsResolution -ZoneName $KeyVaultDnsZoneName -ZoneResourceGroupName $DnsRg -RecordName $NmeIiKeyVaultName -DisplayName 'Intune Insights key vault')) { $DnsCheckFailures++ }
    }
    if ($NmeRtiKeyVaultName) {
        if (-not (Test-NmePrivateDnsResolution -ZoneName $KeyVaultDnsZoneName -ZoneResourceGroupName $DnsRg -RecordName $NmeRtiKeyVaultName -DisplayName 'RTI key vault')) { $DnsCheckFailures++ }
    }
    if (-not (Test-NmePrivateDnsResolution -ZoneName $SqlDnsZoneName -ZoneResourceGroupName $DnsRg -RecordName $NmeSqlServerName -DisplayName 'primary SQL server')) { $DnsCheckFailures++ }
    if ($NmeIiSqlServerName) {
        if (-not (Test-NmePrivateDnsResolution -ZoneName $SqlDnsZoneName -ZoneResourceGroupName $DnsRg -RecordName $NmeIiSqlServerName -DisplayName 'Intune Insights SQL server')) { $DnsCheckFailures++ }
    }
    if ($NmeRtiSqlServerName) {
        if (-not (Test-NmePrivateDnsResolution -ZoneName $SqlDnsZoneName -ZoneResourceGroupName $DnsRg -RecordName $NmeRtiSqlServerName -DisplayName 'RTI SQL server')) { $DnsCheckFailures++ }
    }
    if ($existingDNSZonesSubId) {
        Write-Output "Setting context to subscription $NmeSubscriptionId"
        $context = Set-AzContext -Subscription $NmeSubscriptionId
    }
    if ($DnsCheckFailures -gt 0) {
        Write-Warning "$DnsCheckFailures private DNS record check(s) above did not find the expected record before this script disables public access on the key vault(s) and/or SQL server(s). You may want to abort this run (cancel the job) and re-run once the records exist, rather than let it proceed to disabling public access."
    }
}

# NSG and route table checks run regardless of SkipDNS - they concern the private endpoint and app
# service subnets, not DNS. This script does not create, modify, or inspect the rules of any NSG or
# route table; it only reports what is attached so the customer can review it themselves.
Write-Output "Checking NSGs and route tables on the private endpoint and app service subnets"
$VNet = Get-AzVirtualNetwork -Name $PrivateLinkVnetName -ResourceGroupName $VnetRg
$PrivateEndpointSubnet = Get-AzVirtualNetworkSubnetConfig -Name $PrivateEndpointSubnetName -VirtualNetwork $VNet
$AppServiceSubnet = Get-AzVirtualNetworkSubnetConfig -Name $AppServiceSubnetName -VirtualNetwork $VNet
$NetworkChecksClean = $true

if ($PrivateEndpointSubnet.NetworkSecurityGroup.Id) {
    $NetworkChecksClean = $false
    $PeNsgName = $PrivateEndpointSubnet.NetworkSecurityGroup.Id.Split('/')[-1]
    Write-Warning "The private endpoint subnet '$($PrivateEndpointSubnet.Name)' ($($PrivateEndpointSubnet.AddressPrefix)) has network security group '$PeNsgName' attached. This script did not create this NSG and has not inspected its rules. This script has set privateEndpointNetworkPolicies to Enabled on this subnet, which is the flag that decides whether NSG rules are applied to private endpoints in it - rules that were previously inert on this subnet are now enforced. Before public access is disabled, verify that '$PeNsgName' permits traffic from the app service subnet range ($($AppServiceSubnet.AddressPrefix)) to the private endpoint subnet range ($($PrivateEndpointSubnet.AddressPrefix)) on TCP 443."
}

if ($AppServiceSubnet.NetworkSecurityGroup.Id) {
    $NetworkChecksClean = $false
    $AppNsgName = $AppServiceSubnet.NetworkSecurityGroup.Id.Split('/')[-1]
    Write-Warning "The app service subnet '$($AppServiceSubnet.Name)' has network security group '$AppNsgName' attached. An NSG on the VNet integration subnet applies to outbound traffic unconditionally - no policy flag gates it - so a deny rule in '$AppNsgName' covering the private endpoint subnet range ($($PrivateEndpointSubnet.AddressPrefix)) breaks the same path from the app service to the private endpoints."
}

if ($PrivateEndpointSubnet.RouteTable.Id) {
    $NetworkChecksClean = $false
    $PeRouteTableName = $PrivateEndpointSubnet.RouteTable.Id.Split('/')[-1]
    Write-Warning "The private endpoint subnet '$($PrivateEndpointSubnet.Name)' has route table '$PeRouteTableName' attached. A user-defined route more specific than 0.0.0.0/0 that covers the private endpoint subnet range ($($PrivateEndpointSubnet.AddressPrefix)) will divert private endpoint traffic to whatever next hop it specifies (for example an NVA). A plain 0.0.0.0/0 route is overridden by the more specific system route for a private endpoint and is not the concern."
}

if ($AppServiceSubnet.RouteTable.Id) {
    $NetworkChecksClean = $false
    $AppRouteTableName = $AppServiceSubnet.RouteTable.Id.Split('/')[-1]
    Write-Warning "The app service subnet '$($AppServiceSubnet.Name)' has route table '$AppRouteTableName' attached. A user-defined route more specific than 0.0.0.0/0 that covers the private endpoint subnet range ($($PrivateEndpointSubnet.AddressPrefix)) will divert traffic from the app service to the private endpoints to whatever next hop it specifies (for example an NVA). A plain 0.0.0.0/0 route is overridden by the more specific system route for a private endpoint and is not the concern."
}

if ($NetworkChecksClean) {
    Write-Output "No NSGs or route tables found on the private endpoint or app service subnets."
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
    # The same lockdown is applied to all four vaults (NME, CCL, Intune Insights, RTI). Two notes that
    # apply to every copy of it:
    #  - The VNet rule is the service-endpoint fallback described in the app service VNet integration
    #    region above; it has no effect on traffic arriving over the private endpoint.
    #  - -Bypass None is redundant once PublicNetworkAccess is Disabled, since that blocks the
    #    trusted-services path too. It is set for clarity, not effect. What does matter is that
    #    disabling public network access breaks trusted-service scenarios some customers rely on -
    #    App Service certificate binding from Key Vault, ARM template reference() to a secret, Azure
    #    Backup. That consequence is documented in the notes block rather than worked around here.
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
Set-NmeSqlBaseline -ResourceGroupName $NmeRg -ServerName $NmeSqlServerName -DisplayName 'SQL'

# resolved in Set-NmeVars via tag, then name pattern, then the NMW_RESOURCE fallback tag
switch ($CssaStorageAccount) {
    'Public' {
        Write-Output "Scripted actions storage account left public (CssaStorageAccount=Public)"
    }
    'Private' {
        $StorageAccount = Get-AzStorageAccount -ResourceGroupName $NmeRg -Name $NmeScriptedActionsStorageAccountName -ErrorAction SilentlyContinue
        if ($StorageAccount.PublicNetworkAccess -eq 'Disabled') {
            Write-Output "Storage public access is already disabled"
        }
        else {
            Write-Output "Disabling storage public access"
            Set-AzStorageAccount -PublicNetworkAccess Disabled -ResourceGroupName $NmeRg -Name $StorageAccount.StorageAccountName | Out-Null
        }
        Set-NmeStorageBaseline -ResourceGroupName $NmeRg -StorageAccountName $StorageAccount.StorageAccountName -DisplayName 'scripted actions'
    }
    'Restricted' {
        $StorageAccount = Get-AzStorageAccount -ResourceGroupName $NmeRg -Name $NmeScriptedActionsStorageAccountName -ErrorAction SilentlyContinue
        if ($StorageAccount.PublicNetworkAccess -eq 'Disabled') {
            # This script never relaxes a restriction it, or an earlier run of it, already applied.
            # Moving from Private back to Restricted is a deliberate loosening and must be done by
            # a human in the portal first.
            Write-Warning "The scripted actions storage account's public network access is Disabled, most likely from an earlier run with CssaStorageAccount=Private. This script will not re-enable it automatically. Re-enable public network access on the storage account in the Azure Portal, then re-run with CssaStorageAccount=Restricted to apply the firewall-restricted configuration."
        }
        else {
            $AllowedSubnetIds = Get-NmeLinkedNetworkSubnetIds -Prefix $Prefix
            # Each rule is added independently and its failure is contained. Azure rejects a storage
            # VNet rule when the subnet uses the *regional* Microsoft.Storage service endpoint and
            # sits in a region other than the storage account's (or its paired region):
            # "ResourceBeingAcledHasWrongLocation: Microsoft.Storage resources in <region> cannot be
            # ACL-ed to virtual network <id> in <other region>". A multi-region AVD deployment - a
            # linked VNet in a different region than Nerdio Manager - hits this on the *default*
            # parameter value, and with $ErrorActionPreference = 'Stop' an unhandled failure here
            # aborted the run in the middle of the make-private region, after the key vault and sql
            # server had already been locked down but before the storage baseline and the remaining
            # components were done. Found live (2026-08-12) against a real northcentralus linked VNet
            # while Nerdio Manager was in eastus2. Being unable to allow one AVD VNet through a
            # firewall must never leave the deployment half-configured, so each failure is reported
            # and the run continues.
            $AllowedSubnetCount = 0
            $SkippedSubnetIds = @()
            foreach ($SubnetId in $AllowedSubnetIds) {
                try {
                    Add-AzStorageAccountNetworkRule -ResourceGroupName $NmeRg -Name $StorageAccount.StorageAccountName -VirtualNetworkResourceId $SubnetId -ErrorAction Stop | Out-Null
                    $AllowedSubnetCount++
                }
                catch {
                    $SkippedSubnetIds += $SubnetId
                    Write-Warning "Could not allow subnet '$SubnetId' through the scripted actions storage account's firewall: $($_.Exception.Message) A storage account can only be ACL-ed to a subnet in its own region (or that region's pair) when the subnet uses the regional Microsoft.Storage service endpoint. To allow a subnet in a different region, enable the cross-region Microsoft.Storage.Global service endpoint on it instead, then re-run. This subnet will lose access to the storage account over the public endpoint until then."
                }
            }
            Update-AzStorageAccountNetworkRuleSet -ResourceGroupName $NmeRg -Name $StorageAccount.StorageAccountName -DefaultAction Deny
            Write-Output "Restricted the scripted actions storage account's public endpoint to $AllowedSubnetCount of $($AllowedSubnetIds.Count) linked-network subnet(s)"
            if ($SkippedSubnetIds.Count) {
                Write-Warning "$($SkippedSubnetIds.Count) linked-network subnet(s) could not be allowed through the scripted actions storage account's firewall (see the warnings above for each). The account's public endpoint is now default-deny, so those subnets cannot reach it. Session hosts on them will fail to run scripted actions that need this storage account until either the cross-region Microsoft.Storage.Global service endpoint is enabled on the subnet, or the VNet is peered to the private endpoint VNet (see PeerVnetIds)."
            }
        }
        Set-NmeStorageBaseline -ResourceGroupName $NmeRg -StorageAccountName $StorageAccount.StorageAccountName -DisplayName 'scripted actions'
    }
}

if (($CssaStorageAccount -ne 'Public') -and (Test-NmeCurrentJobIsDownloadMode)) {
    # This job itself just proved download mode still works right now - it downloaded its own script
    # from this storage account before reaching this line. That does not mean the next one will: once
    # public access is restricted here, Azure Automation's sandbox worker (not inside any customer VNet)
    # can no longer reach the storage account to fetch a download-mode job's script body, so every
    # subsequent scripted action - including a later run of this one - would silently fail to download
    # and do nothing, with no exception raised. Inline Script mode avoids this entirely: the script body
    # is sent as a job parameter instead of fetched from storage.
    $CssaInlineModeWarning = "CssaStorageAccount=$CssaStorageAccount restricts the scripted actions storage account's public network access. This job ran in download mode (its script was fetched from that same storage account's public endpoint), so every future scripted-action run in this environment - including a later run of this script - will fail to download its script and silently do nothing unless the Azure Runbook Execution Mode is switched to Inline Script first. In Nerdio Manager, go to Settings > Environment > Nerdio tab > Azure Runbooks Scripted Actions, expand the section, and turn on Enable Parameter Execution. See https://nmehelp.getnerdio.com/hc/en-us/articles/26124302308109-Scripted-actions-for-Azure-Runbooks#Runbook-Execution-Mode---Inline-Script"
    Write-Warning $CssaInlineModeWarning
    Write-Output $CssaInlineModeWarning
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
    Set-NmeStorageBaseline -ResourceGroupName $NmeRg -StorageAccountName $NmeCclStorageAccount.StorageAccountName -DisplayName 'CCL'
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
    Set-NmeStorageBaseline -ResourceGroupName $NmeRg -StorageAccountName $NmeDpsStorageAccount.StorageAccountName -DisplayName 'DPS'
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
    Set-NmeStorageBaseline -ResourceGroupName $NmeRg -StorageAccountName $NmeRtiStorageAccount.StorageAccountName -DisplayName 'RTI'
}
if ($NmeRtiSqlServerName) {
    Disable-NmeSqlPublicAccess -ServerName $NmeRtiSqlServerName -ResourceGroupName $NmeRg -PrivateEndpointSubnetId $PrivateEndpointSubnet.id -DisplayName 'RTI SQL'
    Set-NmeSqlBaseline -ResourceGroupName $NmeRg -ServerName $NmeRtiSqlServerName -DisplayName 'RTI SQL'
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

# make real time insights app service private. Gated on its own MakeRtiAppServicePrivate parameter, not
# MakeAppServicePrivate: unlike Intune Insights, nothing requires RTI to be reachable by the same clients as the
# primary app service, and locking it down silently cuts off any reporting endpoint (AVD session hosts, Windows
# 365 Cloud PCs, Intune-managed devices) without VNet line-of-sight - see the parameter description. This only
# ever writes Disabled, never Enabled, for the same reason as the NME app service block at the end of this
# script: setting the parameter back to false must not re-expose an app the customer locked down. Runs after RTI
# VNet integration (in the #region app service vnet integration block above), per the lesson from the CCL web app.
if ($NmeRtiWebAppName -and $MakeRtiAppServicePrivate) {
    $NmeRtiWebApp = Get-AzWebApp -ResourceGroupName $NmeRg -Name $NmeRtiWebAppName
    $RtiWebAppResource = Get-AzResource -Id $NmeRtiWebApp.id
    if ($RtiWebAppResource.Properties.publicNetworkAccess -eq 'Disabled') {
        Write-Output "RTI app service public access already disabled"
    }
    else {
        Write-Output "Disabling RTI app service public access"
        $RtiWebAppResource.Properties.publicNetworkAccess = "Disabled"
        $RtiWebAppResource | Set-AzResource -Force | Out-Null
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
    Set-NmeSqlBaseline -ResourceGroupName $NmeRg -ServerName $NmeIiSqlServerName -DisplayName 'Intune Insights SQL'
}

# The Cost Calculator web app is always made private, regardless of MakeAppServicePrivate. Nothing
# but the primary Nerdio Manager web app talks to it, and that traffic goes over the private
# network once the private endpoint and VNet integration are in place - so there is no scenario in
# which it needs to be reachable from the internet. This runs here, in the make-private region,
# which is both after CCL VNet integration (in the #region app service vnet integration block
# above) and after the connectivity gate above: locking it down before VNet integration would have
# cut off public access while the private path was still being built, and locking it down before
# the gate would mean a run that aborts there had already disabled CCL's public access - leaving
# this here means an aborted run leaves CCL untouched.
if ($NmeCclWebAppName) {
    $NmeCclWebApp = Get-AzWebApp -ResourceGroupName $NmeRg -Name $NmeCclWebAppName
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

# make intune insights app service private. Gated on MakeAppServicePrivate rather than its own parameter: the
# Intune Insights web app is iframed into the Nerdio Manager interface, so it has to be reachable by exactly the
# same clients as the primary NME app service. Tying it to MakeAppServicePrivate keeps the two consistent - a
# separate switch here would let an admin lock down Intune Insights while leaving NME public (or vice versa),
# breaking the iframe. This only ever writes Disabled, never Enabled. Runs after Intune Insights VNet integration
# (in the #region app service vnet integration block above), per the ordering lesson from the CCL web app.
if ($NmeIiWebAppName -and $MakeAppServicePrivate) {
    $NmeIiWebApp = Get-AzWebApp -ResourceGroupName $NmeRg -Name $NmeIiWebAppName
    $IiWebAppResource = Get-AzResource -Id $NmeIiWebApp.id
    if ($IiWebAppResource.Properties.publicNetworkAccess -eq 'Disabled') {
        Write-Output "Intune Insights app service public access already disabled"
    }
    else {
        Write-Output "Disabling Intune Insights app service public access"
        $IiWebAppResource.Properties.publicNetworkAccess = "Disabled"
        $IiWebAppResource | Set-AzResource -Force | Out-Null
    }
}

#endregion

# Public network access is only ever written when MakeAppServicePrivate explicitly asks for it.
# The previous else branch wrote "Enabled" whenever the parameter was anything other than 'True',
# which meant a customer who locked the app service down manually - or who ran this script once
# with MakeAppServicePrivate = true and re-ran it later to add a component without re-supplying
# the flag - had their app service quietly re-exposed to the internet. Re-enabling public access
# is a deliberate act and is left to the Azure Portal.
if ($MakeAppServicePrivate) {
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