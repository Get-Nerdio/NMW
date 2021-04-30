#description: (Preview) Detects file handles that do not have an associated WVD user session. 
#tags: Nerdio, Preview
<#
Notes:
Currently this script is limited in scope to the single subsciption in which it is run.
If your hostpool ARM Objects are in a different subscription than the storage account they use for fslogix,
this script will NOT account for them.

#>

# Get all storage accounts
$SAList = Get-AzStorageAccount | Select-Object *

# Sort through storage accounts for ones with NMW Tags
$SANMWList = @()
foreach ($SA in $SAList){
    $SATag = $SA.Tags
    if($SATag.Values -match "FILE_STORAGE_ACCOUNT"){
        $SANMWList += $SA
    }
}


# Parse through refined storage account list
$SAHandlelist = @()
foreach ($SANMW in $SANMWList) {
    # Get storage account key, and set context for storage account
    $SAKey = Get-AzStorageAccountkey -ResourceGroupName $SANMW.ResourceGroupName -Name $SANMW.StorageAccountName
    $SAContext = New-AzStorageContext -StorageAccountName $SANMW.StorageAccountName -StorageAccountKey $SAKey.value[0]
    $SANMWShare = Get-AzStorageShare -Context $SAContext
    # Iterate through each share to get all handles and store in $SAHandleList
    foreach ($SAShare in $SANMWShare) {
        $SAHandle = Get-AzStorageFileHandle -ShareName $SAShare.Name -Recursive -context $SAContext | Sort-Object ClientIP,OpenTime,Path
        $SAHandlelist += $SAHandle
    }
}

# Get all user sessions for hostpools in the subscription, then generate an array with AD Usernames

# Get Hostpools
$HostpoolList = Get-AzWvdHostPool | Select-Object *
$UserSessions = @()
foreach($HostPool in $HostPoolList){
    # Get hostpool RG using resource ID
    $HostPoolRG = $HostPool[0].Id.split('/')[-5]
    # Get all sessions in that hostpool
    $Session = (Get-AzWvdUserSession -ResourceGroupName $HostPoolRG -HostPoolName $HostPool.Name).ActiveDirectoryUserName
    if($null -eq $Session){
        continue
    }
    $UserSessions += $Session
}

# Clean $Usersessions of domain name
$ADUsernames = @()
foreach ($ADName in $UserSessions){
    $Name = $ADName.Split('\')[-1]
    $ADUsernames += $Name
}

# Iterate through file handles
foreach ($Handle in $SAHandlelist){

    # if handle doesn't have a path or isn't a VHD file, skip and move to next iteration
    if((!$Handle.Path) -or ($Handle.Path -notmatch '.vhd')){
        continue
    })
    
    $UserAccount = $Handle.Path
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
