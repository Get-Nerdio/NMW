
#description: Deletes FSlogix .vhd(x) files older than specified days and removes any empty directories in the specified Azure Files share.
#tags: Nerdio, FSLogix

<# Variables:
{
  "StorageAccountName": {
    "Description": "Name of the Azure Storage Account.",
    "IsRequired": true
  },
  "ShareName": {
    "Description": "Name of the Azure Files share.",
    "IsRequired": true
  },
  "DaysOld": {
    "Description": "Age of files to check for deletion.",
    "IsRequired": true
  }
}
#>

$ErrorActionPreference = 'Stop'

$StorageContext = New-AzStorageContext -StorageAccountName "$StorageAccountName" -UseConnectedAccount

$Dirs = $StorageContext | Get-AzStorageFile -ShareName "$ShareName" | Where-Object {$_.GetType().Name -eq "AzureStorageFileDirectory"}

# Get files from each directory, check if older than $DaysOld, delete it if it is
foreach ($dir in $Dirs) {
    $Files = Get-AzStorageFile -ShareName "$ShareName" -Path $dir.Name -Context $StorageContext | Get-AzStorageFile
    foreach ($file in $Files) {
        # check if file is not .vhd, if so, skip and move to next iteration
        if ($file.Name -notmatch '\.vhd') {
            write-output "$($file.Name) is not a VHD file, skipping..."
            continue
        }
        # get lastmodified property using Get-AzStorageFile; if lastmodified is older than $DaysOld, delete the file
        $File = Get-AzStorageFile -ShareName "$ShareName" -Path $($dir.name + '/' + $file.Name) -Context $StorageContext
        $LastModified = $file.LastModified.DateTime
        $DaysSinceModified = (Get-Date) - $LastModified
        if ($DaysSinceModified.Days -gt $DaysOld) {
            Write-Output "$($file.Name) is older than $DaysOld days, deleting..." 
            $file | Remove-AzStorageFile 
        }
        else {
            Write-Output "$($file.Name) is not older than $DaysOld days, skipping..."
        }
    }
    # if directory is now empty, delete it
    $Files = Get-AzStorageFile -ShareName "$ShareName" -Path $dir.Name -Context $StorageContext | Get-AzStorageFile
    if ($Files.Count -eq 0) {
        Write-Output "$($dir.Name) is empty, deleting..."
        $dir | Remove-AzStorageFile 
    }
}
