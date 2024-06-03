#description: Move a VM to Availability Zone 2
#tags: Nerdio, Preview

<# Notes:

This Scripted Action will move the VM that it is run against to Availability Zone 2. 
If you want to move a VM to another AZ, clone this scripted action and set the $zone variable below

To run this script, find the session host in Nerdio, and use the menu to the right of the host to 
select "Run script"

#>



#Edit this variable to change the destination zone
$Zone = 2

$ErrorActionPreference = 'Stop'

$subscriptionID = $AzureSubscriptionId
$rgname = $AzureResourceGroupName
$vmname = $AzureVMName

#-------------------------Functions-------------------------------
function Copy-Disk {
    param ($Disk, $Location, $DiskName, $Zone, $RgName)
    $snapshotName = "Snapshot$($DiskName)"
    Write-Output -Message "Creating snapshot $snapshotName from disk $($Disk.Name) location $Location DiskName $DiskName Zone $Zone RgName $RgName"
    $snapshotConfig =  New-azSnapshotConfig -SourceUri $Disk.Id -Location $Location -CreateOption copy -SkuName Standard_ZRS

    try {
        Write-Output -Message "Creating snapshot $snapshotName from disk $($Disk.Name)"
        New-AzSnapshot -Snapshot $snapshotConfig -SnapshotName $snapshotName -ResourceGroupName $RgName | Out-Null
    }
    catch {
        Throw "Unable to create snapshot. Ensure that the Azure region is supported for availability zones and ZRS storage."
    }
    
    $snapshot = Get-AzSnapshot -ResourceGroupName $RgName -SnapshotName $snapshotName
    $diskSku = $Disk.sku | Select-Object -ExpandProperty name
    $diskConfig = New-AzDiskConfig -SkuName $diskSku -Location $Location -CreateOption Copy -SourceResourceId $snapshot.Id -Zone $Zone

    Write-Output -Message "Creating Creating new disk $DiskName from snapshot $snapshotName"
    New-AzDisk -Disk $diskConfig -ResourceGroupName $RgName -DiskName $DiskName| Out-Null
    
    if ($Disk.Encryption.Type -eq 'EncryptionAtRestWithCustomerKey') {
        New-AzDiskUpdateConfig -EncryptionType "EncryptionAtRestWithCustomerKey" -DiskEncryptionSetId $Disk.Encryption.DiskEncryptionSetId | Update-AzDisk -ResourceGroupName $RgName -DiskName $diskName
    }

    Write-Output -Message "Cleaning up snapshot $snapshotName for disk $DiskName"
    Remove-AzSnapshot -ResourceGroupName $RgName -SnapshotName $snapshotName -Force -Verbose | Out-Null
}

function Get-SnapshotOrDefault {
    param ($SnapshotName, $RgName)
    try {
        $snap = Get-AzSnapshot -ResourceGroupName $RgName -SnapshotName $SnapshotName
        return $snap
    }
    catch {
        return $null
    }
}

function Get-DiskOrDefault {
    param ($DiskName, $RgName)
    try {
        $disk = Get-AzDisk -ResourceGroupName $RgName -DiskName $DiskName
        return $disk
    }
    catch {
        return $null
    }
}

function Cleanup-Disk {
    param ($DiskName, $RgName)
    Write-Output -Message "Cleanup Disk $DiskName"
    $snapshotName = "Snapshot$($DiskName)"
    $snap = Get-SnapshotOrDefault -SnapshotName $snapshotName -RgName $RgName
    if ($snap -ne $null) {
        $snap | Remove-AzSnapshot -Force | Out-Null
    }

    $newDisk = Get-DiskOrDefault -DiskName $DiskName -RgName $RgName
    if ($newDisk -ne $null) {
        $newDisk | remove-azdisk -Force | Out-Null
    }
}

#--------------------------Execution-----------------------------

#Log in to your subscription
Set-AzContext -Subscription $subscriptionID

# Check if VM is already in correct AZ
$GetVMinfo = Get-AzVM -ResourceGroupName $rgname -Name $vmName
if ($GetVMinfo.zones -eq $Zone) {
    Write-Output "VM is already in zone $zone"
    Exit
}

#Stop deallocate the VM
$VMStatus = Get-AzVM -ResourceGroupName $rgname -Name $vmname -Status
if ($VMStatus.statuses.displaystatus -notcontains 'VM deallocated') {
    Write-Output -Message "Attempting to Stop VM $vmname" 
    Stop-AzVM -ResourceGroupName $rgname -Name $vmname -Force | Out-Null

}

$SkuInfo = Get-AzComputeResourceSku -Location $GetVMinfo.Location | ? name -eq $GetVMinfo.HardwareProfile.vmsize
if ($null -eq $SkuInfo.locationinfo.zones) {
    Throw "Azure Region $($GetVMinfo.Location) does not support availability zones."
}
elseif ($SkuInfo.locationinfo.zones -notcontains $Zone) {
    Throw "VM size $($GetVMinfo.hardwareprofile.VmSize) is not available in zone $zone."
}

#Export the JSON file; 
Write-Output -Message "Exporting VM configuration to location $env:temp\$vmname.json" 
Get-AzVM -ResourceGroupName $rgname -Name $vmname | ConvertTo-Json -depth 100 | Out-file -FilePath "$env:temp\$vmname.json"

#import from json
Write-Output -Message "Importing VM configuration from location $env:temp\$vmname.json"
$json = "$env:temp\$vmname.json"
$import = Get-Content $json -Raw|ConvertFrom-Json
	#create variables for redeployment 
$rgname = $import.ResourceGroupName
$loc = $import.Location

$vmsize = $import.HardwareProfile.VmSize
$vmname = $import.Name
$disks = $import.StorageProfile.Datadisks
#getting the existing bootdiagnostic stoage account name and parsing the storage account name only
$bootdiagnostics = $import.DiagnosticsProfile.BootDiagnostics.StorageUri
if ($bootdiagnostics) {
    $bootdiag = $bootdiagnostics.Substring(8,$bootdiagnostics.length-31)
}
Write-Output "Set variables for redeployment"

$osDiskName = "OSdiskzone$Zone$vmname"
$osdisk = get-azdisk -ResourceGroupName $rgname -DiskName $import.StorageProfile.OsDisk.Name

try {
    Copy-Disk -Disk $osdisk -Location $loc -DiskName $osDiskName -Zone $zone -RgName $rgname
}
catch {
    Cleanup-Disk -DiskName $osDiskName -RgName $rgname
    throw $_
}

#create the vm config
$NewOSDisKID = get-azdisk -ResourceGroupName $rgname -DiskName $osDiskName | Select-Object -ExpandProperty ID
if ($GetVMinfo.SecurityProfile.EncryptionAtHost) {
    $vm = New-AzVMConfig -VMName $vmname -VMSize $vmsize -Zone $Zone -EncryptionAtHost
    $vm = Set-AzVMOSDisk -VM $vm -ManagedDiskID $NewOSDisKID -name $osDiskName -Caching $import.StorageProfile.OsDisk.Caching -CreateOption attach -Windows -DiskEncryptionSetId $osdisk.Encryption.DiskEncryptionSetId
}
else {
    $vm = New-AzVMConfig -VMName $vmname -VMSize $vmsize -Zone $Zone
    $vm = Set-AzVMOSDisk -VM $vm -ManagedDiskID $NewOSDisKID -name $osDiskName -Caching $import.StorageProfile.OsDisk.Caching -CreateOption attach -Windows #-Linux
}

Write-Output -Message "Adding existing boot diagnostics storage account back $bootdiag" 
#setting bootdiagnotics storage account to the old account
if ($bootdiag) {
    Set-AzVMBootDiagnostic -VM $vm -Enable -ResourceGroupName $rgname -StorageAccountName $bootdiag | Out-Null
}

#network card info
foreach ($nic in $GetVMinfo.NetworkProfile.NetworkInterfaces) {	
	if ($nic.Primary -eq "True")
		{
    		Add-AzVMNetworkInterface -VM $vm -Id $nic.Id -Primary | Out-Null
            Write-Output -Message "Adding back your Primary nic $($nic.Id)" 
       		}
       	else
       		{
       		  Add-AzVMNetworkInterface -VM $vm -Id $nic.Id | Out-Null
              Write-Output -Message "Adding  nic $($nic.Id)" 

            }
}
try {
    foreach ($disk in $GetVMinfo.StorageProfile.DataDisks) {
        $diskname = "$VMname$($disk.Name)"
        $dataDisk = get-azdisk -ResourceGroupName $rgname -DiskName $disk.Name
    
        Copy-Disk -Disk $dataDisk -Location $loc -DiskName $diskName -Zone $zone -RgName $rgname
    
        $DataDisKID = get-azdisk -ResourceGroupName $rgname -DiskName $diskname | Select-Object -ExpandProperty ID
        Write-Output -Message "Adding data disk to new VM $diskname"  
        Add-AzVMDataDisk -VM $vm -Name $diskname -ManagedDiskId $DataDisKID -Caching $disk.Caching -Lun $disk.Lun -CreateOption Attach | Out-Null
    }
}
catch {
    foreach ($disk in $GetVMinfo.StorageProfile.DataDisks) {
        $diskName = "$VMname$($disk.Name)"
        Cleanup-Disk -DiskName $diskName -RgName $rgname
    }
    Cleanup-Disk -DiskName $osDiskName -RgName $rgname
    throw $_
}


Write-Output "Deleting the original VM"
Remove-AzVM -ResourceGroupName $rgname -Name $vmname -Force | Out-Null

try {
    #create the VM
    Write-Output "Creating the new VM"
    New-AzVM -ResourceGroupName $rgname -Location $loc -VM $vm -Tag $GetVMinfo.tags -Verbose | Out-Null
}
catch {
    #restore the VM
    Write-Output "Restore the original VM"
    $OSDisKID = $osdisk | Select-Object -ExpandProperty ID
    if ($GetVMinfo.SecurityProfile.EncryptionAtHost) {
        $vm = New-AzVMConfig -VMName $vmname -VMSize $vmsize -EncryptionAtHost
        $vm = Set-AzVMOSDisk -VM $vm -ManagedDiskID $OSDisKID -name $osdisk.Name -Caching $import.StorageProfile.OsDisk.Caching -CreateOption attach -Windows -DiskEncryptionSetId $osdisk.Encryption.DiskEncryptionSetId
    }
    else {
        $vm = New-AzVMConfig -VMName $vmname -VMSize $vmsize
        $vm = Set-AzVMOSDisk -VM $vm -ManagedDiskID $OSDisKID -name $osdisk.Name -Caching $import.StorageProfile.OsDisk.Caching -CreateOption attach -Windows #-Linux
    }
    if ($bootdiag) {
        Set-AzVMBootDiagnostic -VM $vm -Enable -ResourceGroupName $rgname -StorageAccountName $bootdiag | Out-Null
    }
    foreach ($nic in $GetVMinfo.NetworkProfile.NetworkInterfaces) {	
        if ($nic.Primary -eq "True")
        {
            Add-AzVMNetworkInterface -VM $vm -Id $nic.Id -Primary | Out-Null
        }
        else
        {
            Add-AzVMNetworkInterface -VM $vm -Id $nic.Id | Out-Null
        }
    }
    foreach ($disk in $GetVMinfo.StorageProfile.DataDisks) {
        $createdDiskName = "$VMname$($disk.Name)"
        Cleanup-Disk -DiskName $createdDiskName -RgName $rgname
        $DataDisKID = get-azdisk -ResourceGroupName $rgname -DiskName $disk.Name | Select-Object -ExpandProperty ID
        Add-AzVMDataDisk -VM $vm -Name $disk.Name -ManagedDiskId $DataDisKID -Caching $disk.Caching -Lun $disk.Lun -CreateOption Attach | Out-Null
    }
    New-AzVM -ResourceGroupName $rgname -Location $loc -VM $vm -Tag $GetVMinfo.tags -Verbose | Out-Null

    Cleanup-Disk -DiskName $osDiskName -RgName $rgname
    throw $_
}

Write-Output "Removing original os disk"
$osdisk | remove-azdisk -Force | Out-Null

# If VM was deallocated to begin with, deallocate again before finishing
if ($VMStatus.statuses.displaystatus -notcontains 'VM deallocated') {
    Write-Output -Message "Attempting to Stop VM $vmname" 
    Stop-AzVM -ResourceGroupName $rgname -Name $vmname -Force | Out-Null
}