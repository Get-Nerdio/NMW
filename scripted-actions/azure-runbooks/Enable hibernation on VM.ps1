#description: Enables hibernation on VM
#tags: Nerdio, Preview
<#

Notes: This Script will enables hibernation on VM.
See MS Doc for details: https://learn.microsoft.com/en-us/azure/virtual-machines/hibernate-resume

Prerequisites and configuration limitations:

    The Windows page file can't be on the temp disk.
    Applications such as Device Guard and Credential Guard that require virtualization-based security (VBS) work with hibernation when you enable Trusted Launch on the VM and Nested Virtualization in the guest OS.

    Hibernation support is limited to certain VM sizes and OS versions. Make sure you have a supported configuration before using hibernation.
    Supported VM sizes: https://learn.microsoft.com/en-us/azure/virtual-machines/hibernate-resume#supported-vm-sizes
    Supported Windows versions: https://learn.microsoft.com/en-us/azure/virtual-machines/windows/hibernate-resume-windows?tabs=enableWithPortal%2CenableWithCLIExisting%2CPortalDoHiber%2CPortalStatCheck%2CPortalStartHiber%2CPortalImageGallery#supported-windows-versions
#>

Set-AzContext -SubscriptionId $AzureSubscriptionId | Out-Null

$VM = Get-AzVM -ResourceGroupName $AzureResourceGroupName -Name $AzureVMName
$VM | Stop-AzVM -Force

$DiskId = $VM.StorageProfile.OsDisk.ManagedDisk.Id
$Disk = Get-AzDisk | Where-Object Id -eq $DiskID

if (-not $Disk.SupportsHibernation) {
    $Disk.SupportsHibernation = $True
    Update-AzDisk -ResourceGroupName $Disk.ResourceGroupName -DiskName $Disk.Name -Disk $Disk
}

Update-AzVM -ResourceGroupName $AzureResourceGroupName -VM $VM -HibernationEnabled
