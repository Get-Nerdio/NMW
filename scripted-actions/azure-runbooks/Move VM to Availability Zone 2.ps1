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
if ($VMStatus.powerstate -ne 'deallocated') {
    Write-Output "Starting VM $AzureVMName"
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
Write-Output -Message "Exporting VM configuration to the follwoing location $env:temp \$vmname.json" 
Get-AzVM -ResourceGroupName $rgname -Name $vmname |ConvertTo-Json -depth 100|Out-file -FilePath $env:temp\$vmname.json

#import from json
$json = "$env:temp\$vmname.json"
$import = Get-Content $json -Raw|ConvertFrom-Json
	#create variables for redeployment 
$rgname = $import.ResourceGroupName
$loc = $import.Location

$vmsize = $import.HardwareProfile.VmSize
$vmname = $import.Name
$disks = $import.Datadisks
#getting the existing bootdiagnostic stoage account name and parsing the storage account name only
$bootdiagnostics = $import.DiagnosticsProfile.BootDiagnostics.StorageUri
$bootdiag = $bootdiagnostics.Substring(8,$bootdiagnostics.length-31)

try {
    #Snapshot info OS Disk
    $snapshotOS =  New-azSnapshotConfig -SourceUri $import.StorageProfile.OsDisk.ManagedDisk.Id -Location $loc -CreateOption copy -SkuName Standard_ZRS
    Write-Output "Creating snapshot of VM os disk"
    New-AzSnapshot -Snapshot $snapshotOS -SnapshotName OSdisksnap$vmname -ResourceGroupName $rgname | Out-Null

    $osdisk = get-azdisk -ResourceGroupName $rgname -DiskName $import.StorageProfile.OsDisk.Name

    Write-Output -Message "Creating snapshot OSdisksnap$vmname from disk $($osdisk.Name)" 
    $snapshotOSdisk = Get-AzSnapshot -ResourceGroupName $rgname -SnapshotName OSdisksnap$vmname 
}
catch {
    Throw "Unable to create snapshot. Ensure that the Azure region is supported for availability zones and ZRS storage."
}

Write-Output "Deleting the original VM"
Remove-AzVM -ResourceGroupName $rgname -Name $vmname -Force | Out-Null


#Getdisk OS type
$disktype = get-azdisk -ResourceGroupName $rgname -DiskName $import.StorageProfile.OsDisk.Name
$OSdisktype = $disktype.sku | Select-Object -ExpandProperty name

$diskConfig = New-AzDiskConfig -SkuName $OSdisktype -Location $loc -CreateOption Copy -SourceResourceId $snapshotOSdisk.Id -Zone $Zone
Write-Output -Message "Creating Creating new disk OSdiskzone$Zone$vmname from snapshot OSdisksnap$vmname"  
New-AzDisk -Disk $diskConfig -ResourceGroupName $rgname -DiskName OSdiskzone$Zone$vmname | Out-Null

#Cleanup of snapshot osDISK SNAPSHOT
Write-Output -Message "Cleaning up snapshot OSdisksnap$vmname for disk $($osdisk.name)" 
Remove-AzSnapshot -ResourceGroupName $rgname -SnapshotName OSdisksnap$vmname -Force | Out-Null

#create the vm config
$vm = New-AzVMConfig -VMName $vmname -VMSize $vmsize -Zone $Zone;

Write-Output -Message "Adding existing boot diagnostics storage account back $bootdiag" 
#setting bootdiagnotics storage account to the old account
Set-AzVMBootDiagnostic -VM $vm -Enable -ResourceGroupName $rgname -StorageAccountName $bootdiag | Out-Null

#Select OS Verion type -Windows or -Linux
#OS Disk info
$NewOSDisKID =get-azdisk -ResourceGroupName $rgname -DiskName OSdiskzone$Zone$vmname |Select-Object -ExpandProperty ID
$vm = Set-AzVMOSDisk -VM $vm -ManagedDiskID $NewOSDisKID -name OSdiskzone$Zone$vmname -Caching $import.StorageProfile.OsDisk.Caching -CreateOption attach -Windows #-Linux

#network card info
foreach ($nic in $getvminfo.NetworkProfile.NetworkInterfaces) {	
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


foreach ($disk in $GetVMinfo.StorageProfile.DataDisks) {

$snapshotdata =  New-azSnapshotConfig -SourceUri $disk.ManagedDisk.Id -Location $loc -CreateOption copy -SkuName Standard_ZRS
$SSName = "Snapshot$($disk.Name)$($vmname)"
New-AzSnapshot -Snapshot $snapshotdata -SnapshotName $SSName -ResourceGroupName $rgname | Out-Null

get-azdisk -ResourceGroupName $rgname -DiskName $disk.Name

Write-Output -Message "Creating snapshot $SSName from disk $($disk.Name)" 
$snapshotdatadisk = Get-AzSnapshot -ResourceGroupName $rgname -SnapshotName $SSName

$disktype = get-azdisk -ResourceGroupName $rgname -DiskName $disk.Name
$datadisktype = $disktype.sku | Select-Object -ExpandProperty name

$diskConfig = New-AzDiskConfig -SkuName $datadisktype -Location $loc -CreateOption Copy -SourceResourceId $snapshotdatadisk.Id -Zone $Zone
$diskname = "$VMname$($disk.Name)"

Write-Output -Message "Creating Creating new disk $diskname from snapshot $SSName"  
New-AzDisk -Disk $diskConfig -ResourceGroupName $rgname -DiskName $diskname| Out-Null

$DataDisKID = get-azdisk -ResourceGroupName $rgname -DiskName $diskname | Select-Object -ExpandProperty ID
Write-Output -Message "Adding data disk to new VM $diskname"  
Add-AzVMDataDisk -VM $vm -Name $diskname -ManagedDiskId $DataDisKID -Caching $disk.Caching -Lun $disk.Lun -CreateOption Attach| Out-Null

Write-Output -Message "Cleaning up snapshot $SSName for disk $($disk.name)"  | Out-Null
Remove-AzSnapshot -ResourceGroupName $rgname -SnapshotName $SSName -Force -Verbose | Out-Null
}

Write-Output "Removing original os disk"
$osdisk | remove-azdisk -Force | Out-Null
#create the VM
Write-Output "Creating the new VM"
New-AzVM -ResourceGroupName $rgname -Location $loc -VM $vm -Tag $GetVMinfo.tags -Verbose | Out-Null

# If VM was deallocated to begin with, deallocate again before finishing
if ($VMStatus.powerstate -eq 'deallocated') {
    Write-Output "stopping VM $AzureVMName"
    Write-Output -Message "Attempting to Stop VM $vmname" 
    Stop-AzVM -ResourceGroupName $rgname -Name $vmname -Force | Out-Null

}