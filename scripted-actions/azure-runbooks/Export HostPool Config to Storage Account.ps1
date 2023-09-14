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
  },
  "Concurrency": {
    "Description": "Number of export jobs to run concurrently. Defaults to 5. Azure may suspend/terminate the runbook if too many jobs are running at once.",
    "IsRequired": false,
    "DefaultValue": 5
  }
}
#>

$ErrorActionPreference = 'Stop'

$FileNameDate = Get-Date -Format "yyyy-MM-dd-HH-mm-ss"
$ConcurrentJobs = $Concurrency

# Body of the script goes here
Import-Module NerdioManagerPowerShell 

$NerdioApiClientId = $SecureVars.NerdioApiClientId
$NerdioApiKey = $SecureVars.NerdioApiKey
$NerdioApiTenantId = $SecureVars.NerdioApiTenantId
$NerdioApiScope = $SecureVars.NerdioApiScope
$NerdioApiUrl = $SecureVars.NerdioApiUrl
$StorageAccountKey = $SecureVars."$StorageAcccountKeySecureVarName"

# create a directory for clixml output
$JobOutputDir = "$Env:TEMP\JobOutput"
New-Item -ItemType Directory -Path $JobOutputDir -Force | Out-Null

try {
    Connect-Nme -ClientId $NerdioApiClientId -ClientSecret $NerdioApiKey -ApiScope $NerdioApiScope -TenantId $NerdioApiTenantId -NmeUri $NerdioApiUrl | Out-Null
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
    [array]$HostPools = Get-AzWvdHostPool | where {$_.Name -eq $HostPoolName}
    if ($HostPools.count -gt 1) {
      Write-Output "Multiple host pools with name $HostPoolName found. Exporting all."
    }
}
else {
    throw "Either HostPoolResourceGroup, HostPoolName, or ExportAllHostPools must be specified"
}

Write-Output "Exporting $($HostPools.count) host pools"

# create $concurrentjobs number of jobs and wait for them to finish before creating more
for ($i = 0; $i -lt $HostPools.count; $i += $ConcurrentJobs) {
  Write-Output "Creating maximum $($ConcurrentJobs) jobs, starting at position $i out of $($HostPools.count)"
  $Jobs = @()
  foreach ($hostpool in $HostPools[$i..($i + $ConcurrentJobs - 1)]) {
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
            `$job | export-clixml -path $joboutputdir\$($hostpool.name).xml
          }
          catch {
            `$job.Completed = `$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            `$job.Success = `$false
            `$job.Error = `$_.Exception.Message
            `$job | export-clixml -path $joboutputdir\$($hostpool.name).xml
          }
        }
        catch {
          `$job.Completed = `$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
          `$job.Success = `$false
          `$job.Error = `$_.Exception.Message
          `$job | export-clixml -path $joboutputdir\$($hostpool.name).xml
        }"
      $Job = Start-Job -ScriptBlock ([Scriptblock]::Create($ScriptBlock)) -Name $hostpool.Name
      $Jobs += $Job
  }

  while (($Jobs | Get-Job).State -contains 'Running') {
      Write-Output "Waiting for $(($Jobs | Get-Job | where state -eq 'Running').count) jobs to complete"
      Start-Sleep -Seconds 10
  }
}

$jobInfo = Get-ChildItem -Path $JobOutputDir | Import-Clixml
$jobInfo | select Name, ResourceGroup, Success, Error, FileName, Started, Completed 