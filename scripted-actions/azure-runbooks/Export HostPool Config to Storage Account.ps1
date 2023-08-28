#description: Export Host Pool Configuration
#tags: Nerdio, Preview

<# Notes:
    This scripted action will export the host pool configuration(s) to a json file and upload it to 
    a storage account. 
 
    SETUP INSTRUCTIONS:

    The NerdioManagerPowershell module v 0.4.3 or greater must be installed in Nerdio Manager's 
    runbooks automation account for this script to work. The module can be installed from the 
    PowerShell Gallery.

    If HostPoolResourceGroup is specified, all host pools in the resource group will be exported. 
    
    If HostPoolName is specified, only that host pool will be exported. 
    
    If ExportAllHostPools is true, all host pools the Nerdio app service principal has access to will 
    be exported.

    The following secure variables must be configured in Nerdio Manager and assigned to this script: 
    - NerdioApiClientId: Client ID of the Nerdio REST API
    - NerdioApiKey: Client secret of the Nerdio REST API
    - NerdioApiTenantId: Tenant ID of the Nerdio REST API
    - NerdioApiScope: Scope of the Nerdio REST API
    - NerdioApiUrl: URL of the Nerdio application, e.g. https://your-app-name.azurewebsites.net

    There are two ways to authenticate to the storage account: 
    1. Storage Account Key: When running this script, you can specify the 
       StorageAccountKeySecureVarName. This should correspond to the name of a secure variable 
       that contains the storage account key.
    2. Service Principal: If StorageAccountKeySecureVarName is not specified, the script will 
       attempt to connect to the storage account using the Nerdio app service principal. 
       The Nerdio app service principal must have the "Storage Blob Data Contributor" role 
       on the storage account. 
    
#>

<# Variables:
{
  "HostPoolName": {
    "Description": "Name of the Host Pool. If specified, only this host pool will be exported. Do not specify HostPoolResourceGroup if using this parameter.",
    "IsRequired": false
  },
  "HostPoolResourceGroup": {
    "Description": "If specified, all host pools in this resource group will be exported. Overrides HostPoolName.",
    "IsRequired": false
  },
  "ExportAllHostPools": {
    "Description": "Boolean. If specified, all host pools the Nerdio app service account has access to will be exported. Overrides HostPoolResourceGroup and HostPoolName.",
    "IsRequired": false,
    "DefaultValue": false
  },
  "GatherHostInfo": {
    "Description": "Boolean indicating whether to gather current status of the hosts in the host pool.",
    "IsRequired": false,
    "DefaultValue": false
  },
  "StorageAccountName": {
    "Description": "Name of the Storage Account where json will be exported",
    "IsRequired": true
  },
  "StorageAccountContainer": {
    "Description": "Container in the Storage Account where json will be exported",
    "IsRequired": true
  },
  "StorageAccountKeySecureVarName": {
    "Description": "Name of the NME Secure Variable that contains the Storage Account Key",
    "IsRequired": false
  }
}
#>

$ErrorActionPreference = 'Stop'

$FileNameDate = Get-Date -Format "yyyy-MM-dd-HH-mm-ss"

# Body of the script goes here
Import-Module NerdioManagerPowerShell 

$NerdioApiClientId = $SecureVars.NerdioApiClientId
$NerdioApiKey = $SecureVars.NerdioApiKey
$NerdioApiTenantId = $SecureVars.NerdioApiTenantId
$NerdioApiScope = $SecureVars.NerdioApiScope
$NerdioApiUrl = $SecureVars.NerdioApiUrl
$StorageAccountKey = $SecureVars."$StorageAcccountKeySecureVarName"

try {
    Connect-Nme -ClientId $SecureVars.NerdioApiClientId -ClientSecret $SecureVars.NerdioApiKey -ApiScope $SecureVars.NerdioApiScope -TenantId $SecureVars.NerdioApiTenantId -NmeUri $SecureVars.NerdioApiUrl
}
Catch {
    throw "Unable to connect to Nerdio Manager REST API. Please ensure the NerdioManagerPowershell module is installed in Nerdio Manager's runbook automation account, and that the secure variables are setup per the Notes section of this script."
}


# if ExportAllHostPools is true, use Get-AzWvdHostPool to get all host pools we have access to
if ([System.Convert]::ToBoolean($ExportAllHostPools)) {
    $HostPools = Get-AzWvdHostPool
}
elseif ($HostPoolResourceGroup) {
  # get all host pools in the rg
  $HostPools = Get-AzWvdHostPool -ResourceGroupName $HostPoolResourceGroup
}
elseif ($HostPoolName) {
    $HostPools = Get-AzWvdHostPool | where {$_.Name -eq $HostPoolName}
    if ($HostPools.count -gt 1) {
      Write-Output "Multiple host pools with name $HostPoolName found. Exporting all."
    }
}
else {
    throw "Either HostPoolResourceGroup, HostPoolName, or ExportAllHostPools must be specified"
}

Write-Output "Exporting $($HostPools.count) host pools"

if ($StorageAccountKeySecureVarName){
    $SAContext = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $StorageAccountKeySecureVarName -Protocol Https -ErrorAction Stop
    write-output "Using storage account key to connect to $StorageAccountName"
}
else {
    try {
        $SAContext = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount -Protocol Https -ErrorAction Stop
        Write-Output "Using Nerdio app service principal to connect to $StorageAccountName"
    }
    catch {
        throw "Storage Account Key not specified; unable to connect to $StorageAccountName with Nerdio app service principal. Either configure a storage account key or grant the Nerdio app service account the `"Storage Blob Data Contributor`" role the storage account."
    }
}

$Jobs = @()
foreach ($hostpool in $HostPools) {
    $HpResourceGroup = $hostpool.id -split '/' | select -Index 4
    $FileName = $hostpool.Name + "-$FileNameDate" + '.json'
    
    $ScriptBlock = "
    try {
      `$erroractionpreference = 'stop'
        `$Job = @{
          Name = '$($hostpool.Name)'
          FileName = '$FileName'
          ResourceGroup = '$HpResourceGroup'
          Success = `$null
          Error = `$null
          Started = '$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")'
          Completed = `$null
        }
        import-module NerdioManagerPowerShell
        import-module Az.Storage
        `$connect = Connect-Nme -ClientId $NerdioApiClientId -ClientSecret $NerdioApiKey -ApiScope $NerdioApiScope -TenantId $NerdioApiTenantId -NmeUri $NerdioApiUrl 
        $(
          if ($StorageAccountKey) {
            "`$Context = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $StorageAccountKey -Protocol Https -ErrorAction Stop"
          }
          else {
            "`$kvConnection = Get-AutomationConnection -Name $KeyVaultAzureConnectionName"
            "Connect-AzAccount -ServicePrincipal -Tenant $($kvConnection.TenantID) -ApplicationId $($kvConnection.ApplicationID) -CertificateThumbprint $($kvConnection.CertificateThumbprint) -Environment $KeyVaultAzureEnvironment -Subscription $AzureSubscriptionId | Out-Null"
            "`$Context = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount -Protocol Https -ErrorAction Stop"
          }
        )
        Export-NmeHostPoolConfig -HostPoolName $($hostpool.name) -SubscriptionId $AzureSubscriptionId -ResourceGroup $hpresourcegroup $(if(([System.Convert]::ToBoolean($GatherHostInfo))){'-IncludeHosts'}) | Out-File -FilePath '$Env:TEMP\$FileName'
        try {
          Set-AzStorageBlobContent -Container $StorageAccountContainer -File '$Env:TEMP\$FileName' -Blob $FileName -context `$Context -Force | Out-Null
          `$job.Success = `$true
          `$job.Completed = `$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
          `$job
        }
        catch {
          `$job.Completed = `$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
          `$job.Success = `$false
          `$job.Error = `$_.Exception.Message
          `$job
        }
      }
      catch {
        `$job.Completed = `$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        `$job.Success = `$false
        `$job.Error = `$_.Exception.Message
        `$job
      }"
    $Job = Start-Job -ScriptBlock ([Scriptblock]::Create($ScriptBlock))
    $Jobs += $Job
}

while ($Jobs.State -contains 'Running') {
    Write-Output "Waiting for $(($Jobs | where state -eq 'Running').count) jobs to complete"
    Start-Sleep -Seconds 10
}

$Jobs | Receive-Job | Select Name, ResourceGroup, Success, Error, FileName, Started, Completed
