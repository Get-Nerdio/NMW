#description: Detects file handles that do not have an associated user session in WVD
#tags: Nerdio, Preview

<#
This script will detect file handles that do not have an associated user session in WVD. 
The variables below MUST be adjusted to target the correct storage account and hostpools

See bottom of this script for important notes and possible issues.
#>

# ___________________________ Variables  ___________________________ 
# !!!!!!!!!!!! Following Variables MUST be adjusted !!!!!!!!!!!!!!!!
# Resource Group that holds your FSLogix Storage Account
$StorageResourceGroupName = "sa_rg_name"
# SubscriptionID for storage account (the ID, NOT the name)
$StorageSubscriptionID = "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
# storage account name (located at Xs in this path: \\XXXXXXX.file.core.windows.net\example)
$StorageName = "sa_name"
# file share name (located at Xs in this path: \\example.file.core.windows.net\XXXXXXXX)
$ShareName = "share_name"
# Resource group that holds your hostpools
$HostPoolResourceGroupName = "hp_rg_name"
# SubscriptionID for hostpools (the ID, NOT the name)
$HostPoolSubscriptionID = "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"


# ___________________________ Script Logic ___________________________ 

# Switch context for subscription with Storage Account
$null = Set-AzContext -SubscriptionId $StorageSubscriptionID

# Get storage account key, and set context for storage account. retreive file handles and store in variable
$SAKey = Get-AzStorageAccountkey -ResourceGroupName $StorageResourceGroupName -Name $StorageName
$SAContext = New-AzStorageContext -StorageAccountName $StorageName -StorageAccountKey $SAKey.value[0]
$SAHandles = Get-AzStorageFileHandle -ShareName $ShareName -Recursive -context $SAContext | Sort-Object ClientIP,OpenTime,Path

# switch context to subscription with hostpool
$null = Set-AzContext -SubscriptionId $HostPoolSubscriptionID

# Get all user sessions for hostpools in the subscription, then generate an array with AD Usernames
$HostpoolList = (Get-AzWvdHostPool -ResourceGroupName $HostPoolResourceGroupName).Name
$UserSessions = @()
foreach($HostPool in $HostpoolList){
    $Session = (Get-AzWvdUserSession -ResourceGroupName $HostPoolResourceGroupName -HostPoolName $HostPool).ActiveDirectoryUserName
    if($null -eq $Session){
        continue
    }
    $UserSessions += $Session
}

# Clean Usersessions of domain name
$ADUsernames = @()
foreach ($ADName in $UserSessions){
    $Name = $ADName.Split('\')[-1]
    $ADUsernames += $Name
}

# Iterate through file handles
foreach ($Handle in $SAHandles){

    # if handle doesn't have a path or isn't a VHD file, skip and move to next iteration
    if((!$Handle.Path) -or ($Handle.Path -notmatch '.vhd')){
        continue
    }

    # Parse handle file path for username 
    # !!!!!!!!!!! This will require changes if not using default FSLogix naming !!!!!!!!!!!!!
    $UserAccount = ($handle.Path).Split('_')[-2].trim('/Profile')
    
    # Take username from filepath and cross reference against usernames retrieved from sessions query
    foreach ($ADUser in $ADUsernames){
        if ($UserAccount -match $ADUser){
            $match = $true
        }
    }

    # if there was no match after cross referencing, print info on the file handle
    if (!$match){

        Write-Output "INFO: Filehandle for $useraccount doesn't have matching user session. IP: $($Handle.ClientIP) File: $($Handle.path)"
    }

    $match = $false
}


<# ___________________________ Important Notes  ___________________________ 
Currently this script is limited in scope to a single subsciptions for hostpools.
If your hostpool ARM Objects are spread across multiple subscriptions but the storage account they use is not,
this script will NOT account for them. This script expects a one-to-one relationship between
the subscription that holds the hostpools and the storage account that holds their FSLogix profiles.

Also, this script assumes you are using standard settings for FSLogix porfile file naming, which looks like this:
"S-1-5-21-1231231231-123123123123-1231231231-1610_johndoe/Profile_johndoe.vhdx"
#>
