#description: (PREVIEW) Backup Nerdio App components to a storage account. Read Notes within before use.
#tags: Nerdio, Preview
<#
Notes:
The App service plan used by the NMW App MUST be standard or premium in order to enable backups and use
this script effectively.

This script backs up NMW app components to a specified storage account (or creates one if needed). 
See https://nmw.zendesk.com/hc/en-us/articles/4731671906071-Back-Up-and-Restore-Nerdio-Manager-Configuration
for more details on methods used by this script.

When running the scripted action, run it using the subscription that holds the Nerdio NMW app service.
When using a seperate subscription, the "Nerdio-nmw-app" service prinipal MUST have permissions to the 
subscription, or resource group specified, to create a storage account.

It is recomended to adjust the variables below to store this data in another region and resource group
if redundancy is desired.
#>


#________________ Adjustable Variables ________________ 
#             (Recommended to change these)

# ID of Subscription that the storage account that holds backups will use. 
# Optional, leave $null to use sub selected by scripted action UI
$BackupSubscriptionID = "$null"

# Resource group to hold storage account.
# Optional, leave $null to use same resource group as NMW app (Not recommended)
$BackupResourceGroup = "$null"

# Name of storage account for backup data. 
# Optional, leave $null to auto-generate storage account name
$BackupStorageAccount = "$null"

# Azure region to create storage acount. Recomended to use same region as 
# resource group specified above as best practice.
# Use the powershell command get-azlocation to determine the correct value for your desired location.
# Optional, leave $null to use same region as NMW app (Not recommended)
$BackupLocation = "$null"

# Name for container within storage account to store data
$blobContainerName = 'nmw-backups'

# Number of days to hold App data. (KV data is stored indefinitely)
$retentionPeriodInDays = 10


#__________________ Script Logic __________________ 
#             (Alter at your own Risk)

# get current context used for the app in order to switch back
$NMWContext = Get-AzContext

# search for NMW app
$NMWAppQuery = Get-AzWebApp | where-object {$_.name -match "nmw-app"}


# query second time with more verbose attributes to get more results from get-azwebapp cmdlet
$NMWApp = Get-AzWebApp -ResourceGroupName $NMWAppQuery.ResourceGroup -Name $NMWAppQuery.Name -ErrorAction Stop

# get app service plan
$NMWAppPlanResource = Get-AzResource -ResourceId $NMWApp.ServerFarmId -ErrorAction Stop
$NMWAppPlan = Get-AzAppServicePlan -ResourceGroupName $NMWAppPlanResource.ResourceGroupName -Name $NMWAppPlanResource.Name -ErrorAction Stop


# check app service plan tier
if ($NMWAppPlan.Sku.Tier -notmatch 'Standard|Premium') {
    Write-Output "ERROR: Please upgrade app service plan to Standard or Premium tier to enable backups"
    Write-Error "ERROR: Please upgrade app service plan to Standard or Premium tier to enable backups" -ErrorAction Stop
}

# Use NMWApp's Resource group, location, and subscription for backup target, if none specfied
$RGName = $BackupResourceGroup
if(!$RGName){
    $RGName = $NMWApp.ResourceGroup
}
$NMWLocation = $BackupLocation
if(!$NMWLocation){
$NMWLocation = $NMWApp.Location
}

# Switch over to subscription to make backup storage account, if specified
if($BackupSubscriptionID){
    try {
        Write-Output "INFO: Swtiching to Subscription used by Storage Account"
        Set-AzContext -SubscriptionId $BackupSubscriptionID
    }
    catch{
        Write-Error "ERROR: Invalid subscription ID provided: $backupsubscriptionID.
        Make sure the nerdio-nmw-app service principal has an RBAC role in this subscription 
        and that the ID is correct."
        exit 
    }
}

# get azure context to grab ID subscription of NMW App
$Context = Get-AzContext
$ContextSubID = $context.Subscription.Id


# generate Storage Account name using first 8 char of subscription ID, if none specified
if(!$BackupStorageAccount){
    $SASuffix = ($ContextSubID).Substring(0,8)
    $SAName = "nmwbackup$SASuffix"
}
Write-Output "INFO: Expected Storage Account Name: $SAName"


# check if storage account exists, create a new one if it doesnt
$SAResource = Get-AzStorageAccount -ResourceGroupName $RGName -Name $SAName -ErrorAction SilentlyContinue
if($SAResource){
    Write-Output "INFO: Storage Account $SAName already exists, continuing with existing storage account"
}
else {
    Write-Output "INFO: Creating new storage account: $SAName"

    $SAParams = @{
        ResourceGroupName = $RGName
        AccountName = $SAName
        Location = $NMWLocation
        SkuName = "Standard_GRS"
        Kind = "StorageV2"
    }

    $SAResource = New-AzStorageAccount @SAParams
}

# switch back to NMW context
Write-Output "INFO: Switching to subscription used by NMW App"
Set-AzContext $NMWContext

# get keyVault from app settings
$appSettings = @{}
ForEach ($setting in $NMWApp.SiteConfig.AppSettings) {
    $appSettings[$setting.Name] = $setting.Value
}
$vaultName = $appSettings["Deployment:KeyVaultName"]
$vault = Get-AzKeyVault -VaultName $vaultName -ErrorAction Stop


# ensure permission to get secrets and certs. If no permissions found, give to nmw-app
$NMWPermissions = $vault.AccessPolicies | Where-Object { $_.DisplayName -match $context.Account}
Write-Output $NMWPermissions
$permissionsToSecrets = New-Object Collections.Generic.List[string]
$permissionsToCert = New-Object Collections.Generic.List[string]
if ($NMWPermissions) {
    $permissionsToSecrets.AddRange($NMWPermissions.PermissionsToSecrets)
    $permissionsToCert.AddRange($NMWPermissions.PermissionsToCertificates)
}
if (!$permissionsToSecrets.Contains("get")) {
    $permissionsToSecrets.Add("get")
}
if (!$permissionsToSecrets.Contains("backup")) {
    $permissionsToSecrets.Add("backup")
}
if (!$permissionsToSecrets.Contains("list")) {
    $permissionsToSecrets.Add("list")
}
if (!$permissionsToCert.Contains("backup")) {
    $permissionsToCert.Add("backup")
}
if (!$permissionsToCert.Contains("list")) {
    $permissionsToCert.Add("list")
}

$KVPolicyParams = @{
    vaultname                 = $vaultName
    ObjectID                  = $NMWPermissions.ObjectId
    PermissionsToSecrets      = $permissionsToSecrets
    PermissionsToCertificates = $permissionsToCert
}
Set-AzKeyVaultAccessPolicy @KVPolicyParams

# get DB connection string from keyVault
$secret = Get-AzKeyVaultSecret -VaultName $vaultName -Name "ConnectionStrings--DefaultConnection" -ErrorAction Stop -WarningAction Ignore
$connectionString = [System.Net.NetworkCredential]::new("", $secret.SecretValue).Password 


# create db settings object for backup configuration
$dbSettings = New-Object -TypeName Microsoft.Azure.Management.WebSites.Models.DatabaseBackupSetting
$dbSettings.Name = "nmw-app-db"
$dbSettings.DatabaseType = "SqlAzure"
$dbSettings.ConnectionStringName = "DefaultConnection"
$dbSettings.ConnectionString = $connectionString

# enter storage account context if specified
if($BackupSubscriptionID){
    Write-Output "INFO: Swtiching to Subscription used by Storage Account"
    Set-AzContext -SubscriptionId $BackupSubscriptionID
}


# configure storage account context
$keys = Get-AzStorageAccountKey -ResourceGroupName $SAResource.ResourceGroupName -Name $SAResource.StorageAccountName
$storageContext = New-AzStorageContext -StorageAccountName $SAResource.StorageAccountName -StorageAccountKey $keys[0].Value


# make sure blob container exists
$blobContainer = Get-AzStorageContainer -Context $storageContext -Name $blobContainerName -ErrorAction SilentlyContinue
if (!$blobContainer) {
    $blobContainer = New-AzStorageContainer -Context $storageContext -Name $blobContainerName -Permission Off
}


# generate sasUri for blob container
$sasUri = New-AzStorageContainerSASToken -Context $storageContext -Name $blobContainerName -Permission rwdl -ExpiryTime (Get-Date).AddYears(100) -FullUri

# switch back to app sub
Write-Output "INFO: Switching to subscription used by NMW App"
Set-AzContext $NMWContext

# enable backups
$AppBackupConfig = @{
    webapp = $NMWApp
    FrequencyInterval = 1
    FrequencyUnit = 'Day'
    RetentionPeriodInDays = $retentionPeriodInDays
    KeepAtLeastOneBackup = $true
    starttime = (Get-Date)
    StorageAccountUrl = $sasUri
    Databases = $dbSettings
    Erroraction = 'stop'
}
Edit-AzWebAppBackupConfiguration @AppBackupConfig

# prepare temp file structure for azure runbook worker
$targetFolder = Join-Path -Path $env:TEMP -ChildPath keyvault-backup
$secretsPath = Join-Path -Path $targetFolder secrets
$certificatesPath = Join-Path -Path $targetFolder certificates
if (Test-Path $targetFolder) {
    Remove-Item -Path $targetFolder -Recurse -Force
}
New-Item -ItemType directory -Path $targetFolder -Name secrets
New-Item -ItemType directory -Path $targetFolder -Name certificates


# backup secrets
Get-AzKeyVaultSecret -VaultName $vaultName -WarningAction Ignore | Where-Object { $_.ContentType -ne 'application/x-pkcs12' } | ForEach-Object {
    Write-Output 'INFO: Processing secret: ' $_.Name
    $itemPath = Join-Path -Path $secretsPath -ChildPath $_.Name
    Backup-AzKeyVaultSecret -VaultName $vaultName -Name $_.Name -OutputFile $itemPath -Force
}

# backup certificates
Get-AzKeyVaultCertificate -VaultName $vaultName | ForEach-Object {
    Write-Output 'INFO: Processing certificate: ' $_.Name
    $itemPath = Join-Path -Path $certificatesPath -ChildPath $_.Name
    Backup-AzKeyVaultCertificate -VaultName $vaultName -Name $_.Name -OutputFile $itemPath -Force
}


# zip secrets and certs
$zipPath = Join-Path $env:TEMP keyvault-backup.zip
Compress-Archive -Path (Join-Path $targetFolder *) -DestinationPath $zipPath -Force
Remove-Item $targetFolder -Recurse -Force

# Switch back to storage context to send files to storage
if($BackupSubscriptionID){
    Write-Output "INFO: Swtiching to Subscription used by Storage Account"
    Set-AzContext -SubscriptionId $BackupSubscriptionID
}

# upload zipped file to storage account
Set-AzStorageBlobContent -Context $storageContext -Container $blobContainerName -File "$env:TEMP\keyvault-backup.zip" -Force
