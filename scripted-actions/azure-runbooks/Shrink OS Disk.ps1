#description: Resize VM OS disk to 64GB
#tags: Nerdio, Preview
<#

Notes:
This script changes the os disk VM it is run against to 64GB. The disk can be changed to other sizes by changing the $DiskSizeGB variable.

If the amount of data on the os disk is greater than the new size, the script will throw an error and will not resize the disk.

Requires and turns on the defrag service for disk partitioning.

This script requires the target VM to be Windows 10 (Windows 7 is not supported).

This script is intended to be used on a desktop image VM. After shrinking the OS disk of a desktop image VM be sure to run "set as image" operation to be able to use the new image for session host creation.
#>


$ErrorActionPreference = "Stop"
$DiskSizeGB = 64 # Set to the desired size of the new OS Disk

$NewPartitionSize = $DiskSizeGB - 1
$PartitionScriptBlock = @"
if ((Get-Service -Name defragsvc).Status -eq "Stopped") {
    write-output "Defragsvc started"
    Set-Service -Name defragsvc -Status Running -StartupType Manual
}
`$Partition = get-partition | Where-Object isboot -eq `$true 
`$Disk = Get-CimInstance -ClassName Win32_LogicalDisk | Where-Object DeviceID -eq `$(`$partition.DriveLetter + ':') 
`$DiskUsed = `$Disk.Size - `$Disk.FreeSpace
write-output ("Disk space used: " + `$DiskUsed / 1GB + "GB")

if (`$DiskUsed / 1GB -lt $NewPartitionSize) {
    `$Partition | Resize-Partition -Size $NewPartitionSize`GB
}
else {
    Throw "Not enough free space to resize partition"
}
"@ 
$PartitionScriptBlock | Out-File .\partitionscriptblock.ps1

Start-AzVM -ResourceGroupName $AzureResourceGroupName -Name $AzureVMName 
$Result = Invoke-AzVMRunCommand -ResourceGroupName $AzureResourceGroupName -VMName $AzureVMName -ScriptPath .\partitionscriptblock.ps1 -CommandId runpowershellscript
Stop-AzVM -ResourceGroupName $AzureResourceGroupName -Name $AzureVMName -Force

if ($Result.Value[1].Message -match "Not enough free space") {
    Write-Output $Result.Value[1].Message
    Throw "Not enough free space to resize partition"
}
if ($Result.Value[1].Message -match "The partition is already the requested size") {
    Write-Output $Result.Value[1].Message
    Throw "The partition is already the requested size."
}

Write-Output ("INFO: " + $Result.Value[0].Message)

$VMName = $AzureVMName 
$VM = Get-AzVM -ResourceGroupName $AzureResourceGroupName -Name $VMName  
$DiskId = $VM.StorageProfile.OsDisk.ManagedDisk.Id

# Following script adapted from https://github.com/jrudlin/Azure/blob/master/General/Shrink-AzDisk.ps1

#Provide the name of your resource group where snapshot is created
$resourceGroupName = $AzureResourceGroupName

# Get Disk from ID
$Disk = Get-AzDisk | Where-Object Id -eq $DiskID

# Get VM/Disk generation from Disk
$HyperVGen = $Disk.HyperVGeneration

# Get Disk Name from Disk
$DiskName = $Disk.Name

# Get SAS URI for the Managed disk
$SAS = Grant-AzDiskAccess -ResourceGroupName $resourceGroupName -DiskName $DiskName -Access 'Read' -DurationInSecond 600000;

#Provide storage account name where you want to copy the snapshot - the script will create a new one temporarily
$storageAccountName = "shrink" + [system.guid]::NewGuid().tostring().replace('-','').substring(1,18)

#Name of the storage container where the downloaded snapshot will be stored
$storageContainerName = $storageAccountName

#Provide the name of the VHD file to which snapshot will be copied.
$destinationVHDFileName = "$($VM.StorageProfile.OsDisk.Name).vhd"

#Create the context for the storage account which will be used to copy snapshot to the storage account
Write-Output "INFO: Creating temporary storage for disk snapshot: $storageAccountName" 
$StorageAccount = New-AzStorageAccount -ResourceGroupName $resourceGroupName -Name $storageAccountName -SkuName Standard_LRS -Location $VM.Location
$destinationContext = $StorageAccount.Context
$container = New-AzStorageContainer -Name $storageContainerName -Permission Off -Context $destinationContext

#Copy the snapshot to the storage account and wait for it to complete
Write-Output "INFO: Copying snapshot to storage account"
Start-AzStorageBlobCopy -AbsoluteUri $SAS.AccessSAS -DestContainer $storageContainerName -DestBlob $destinationVHDFileName -DestContext $destinationContext
while (($state = Get-AzStorageBlobCopyState -Context $destinationContext -Blob $destinationVHDFileName -Container $storageContainerName).Status -ne "Success") { $state; Start-Sleep -Seconds 20 }
$state

# Revoke SAS token
Revoke-AzDiskAccess -ResourceGroupName $resourceGroupName -DiskName $DiskName

# Emtpy disk to get footer from
$emptydiskforfootername = "$($VM.StorageProfile.OsDisk.Name)-empty.vhd"
Write-Output "INFO: Empty disk to get footer from: $emptydiskforfootername"

$diskConfig = New-AzDiskConfig `
    -Location $VM.Location `
    -CreateOption Empty `
    -DiskSizeGB $DiskSizeGB `
    -HyperVGeneration $HyperVGen

$dataDisk = New-AzDisk `
    -ResourceGroupName $resourceGroupName `
    -DiskName $emptydiskforfootername `
    -Disk $diskConfig

$VM = Add-AzVMDataDisk `
    -VM $VM `
    -Name $emptydiskforfootername `
    -CreateOption Attach `
    -ManagedDiskId $dataDisk.Id `
    -Lun 63

Update-AzVM -ResourceGroupName $resourceGroupName -VM $VM

$VM | Stop-AzVM -Force


# Get SAS token for the empty disk
$SAS = Grant-AzDiskAccess -ResourceGroupName $resourceGroupName -DiskName $emptydiskforfootername -Access 'Read' -DurationInSecond 600000;

# Copy the empty disk to blob storage
Write-Output "Copy empty disk to storage account"
Start-AzStorageBlobCopy -AbsoluteUri $SAS.AccessSAS -DestContainer $storageContainerName -DestBlob $emptydiskforfootername -DestContext $destinationContext
while(($state = Get-AzStorageBlobCopyState -Context $destinationContext -Blob $emptydiskforfootername -Container $storageContainerName).Status -ne "Success") { $state; Start-Sleep -Seconds 20 }
$state

# Revoke SAS token
Revoke-AzDiskAccess -ResourceGroupName $resourceGroupName -DiskName $emptydiskforfootername

# Remove temp empty disk
Remove-AzVMDataDisk -VM $VM -DataDiskNames $emptydiskforfootername
Update-AzVM -ResourceGroupName $resourceGroupName -VM $VM

# Delete temp disk
Remove-AzDisk -ResourceGroupName $resourceGroupName -DiskName $emptydiskforfootername -Force;

# Get the blobs
$emptyDiskblob = Get-AzStorageBlob -Context $destinationContext -Container $storageContainerName -Blob $emptydiskforfootername
$osdisk = Get-AzStorageBlob -Context $destinationContext -Container $storageContainerName -Blob $destinationVHDFileName

$footer = New-Object -TypeName byte[] -ArgumentList 512
Write-Output "INFO: Get footer of empty disk"

$downloaded = $emptyDiskblob.ICloudBlob.DownloadRangeToByteArray($footer, 0, $emptyDiskblob.Length - 512, 512)

$osDisk.ICloudBlob.Resize($emptyDiskblob.Length)
$footerStream = New-Object -TypeName System.IO.MemoryStream -ArgumentList (,$footer)
Write-Output "INFO: Write footer of empty disk to OSDisk"
$osDisk.ICloudBlob.WritePages($footerStream, $emptyDiskblob.Length - 512)

Write-Output -InputObject "INFO: Removing empty disk blobs"
$emptyDiskblob | Remove-AzStorageBlob -Force


#Provide the name of the Managed Disk
$NewDiskName = "$DiskName" + "-$DiskSizeGB`GB"
Write-Output "INFO: New managed disk name: $NewDiskName"

#Create the new disk with the same SKU as the current one
$accountType = $Disk.Sku.Name
Write-Output "INFO: Account type SKU: $accountType"

# Get the new disk URI
$vhdUri = $osdisk.ICloudBlob.Uri.AbsoluteUri
Write-Output "INFO: New disk URI: $vhdUri"

# Specify the disk options
$diskConfig = New-AzDiskConfig -AccountType $accountType -Location $VM.location -DiskSizeGB $DiskSizeGB -SourceUri $vhdUri -CreateOption Import -StorageAccountId $StorageAccount.Id -HyperVGeneration $HyperVGen
Write-Output "INFO: Created new disk config"

#Create Managed disk
$NewManagedDisk = New-AzDisk -DiskName $NewDiskName -Disk $diskConfig -ResourceGroupName $resourceGroupName
Write-Output "INFO: Created new disk"

$VM | Stop-AzVM -Force

# Set the VM configuration to point to the new disk  
Set-AzVMOSDisk -VM $VM -ManagedDiskId $NewManagedDisk.Id -Name $NewManagedDisk.Name

# Update the VM with the new OS disk
Update-AzVM -ResourceGroupName $resourceGroupName -VM $VM

$VM | Start-AzVM

# Increased sleep timer for VM stability on boot
start-sleep 90

$VmTestScriptBlock = @'
$env:ComputerName
'@ 
$VmTestScriptBlock | Out-File .\vmtestscriptblock.ps1

Try {
    $Result = Invoke-AzVMRunCommand -ResourceGroupName $AzureResourceGroupName -VMName $AzureVMName  -ScriptPath .\vmtestscriptblock.ps1 -CommandId runpowershellscript 

    if ($Result.Status -eq 'Succeeded') {
        Write-Output "INFO: Disk swap succeeded. Removing old osDisk"
        # Delete old Managed Disk
        Remove-AzDisk -ResourceGroupName $resourceGroupName -DiskName $DiskName -Force;

        # Delete old blob storage
        $osdisk | Remove-AzStorageBlob -Force
    }
    else {
        Write-Output "INFO: VM did not boot with new disk. Reverting to original osDisk"
        $VM | Stop-AzVM -Force 
        Set-AzVMOSDisk -VM $VM -ManagedDiskId $DiskId -Name $DiskName
        Update-AzVM -ResourceGroupName $resourceGroupName -VM $VM
        #Remove-AzDisk -ResourceGroupName $resourceGroupName -DiskName $NewDiskName -Force

    }
}
Catch {
    Write-Output "INFO: VM did not boot with new disk. Reverting to original osDisk"
    $VM | Stop-AzVM -Force 
    Set-AzVMOSDisk -VM $VM -ManagedDiskId $DiskId -Name $DiskName
    Update-AzVM -ResourceGroupName $resourceGroupName -VM $VM
    #Remove-AzDisk -ResourceGroupName $resourceGroupName -DiskName $NewDiskName -Force
    Throw $_

}
Finally {
    # Delete temp storage account
    $StorageAccount | Remove-AzStorageAccount -Force
}