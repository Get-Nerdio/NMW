#description: Enables OS disk encryption on session host VMs. Creates a new KeyVault, if required. Requires restart and downtime of VM while encrypting.
#tags: Nerdio
<# 
Notes:
!==== WARNING ====!
THIS SCRIPT WILL RESTART THE VM, AND REQUIRES A 10-15 MINUTE DOWNTIME WHILE DISKS ARE ENCRYPTED.
ANY CURRENT USER SESSIONS WILL BE INTERRUPTED!
!=================!

This script will enable VM Disk encryption. 
See MS Doc for details: https://docs.microsoft.com/en-us/azure/virtual-machines/disk-encryption

Note: when using existing Keyvault it needs be in the same subscription and location as the VM
If no existing keyvault is specified, it will create a new keyvault named "vm-encrypt-kv-XXXXXXXX"
The Nerdio App must have permissions to the subscription that the VM is in to run this script successfully,
and have necessary access policies to use the Keyvault.
#>

# Uncomment and Edit this variable with keyvault name if using a pre-existing keyvault
# $EncryptKVName = "<Keyvault-name>"

# Ensure context is using correct subscription
Set-AzContext -SubscriptionId $AzureSubscriptionId | Out-Null

# Query Azure for VM object using name, start VM
$AzVM = Get-AzVM -Name $AzureVMName -ResourceGroupName $AzureResourceGroupName


# Check if VM is already encrypted
$report = Get-AzVmDiskEncryptionStatus -VMName $AzVM.Name -ResourceGroupName $AzVM.ResourceGroupName
if($report.OsVolumeEncrypted -notmatch "NotEncrypted"){
    Write-Output "INFO: OSDisk is already Encrypted. Stopping Script."
    exit
}

# Start VM to begin encryption
Write-Output "INFO: Starting VM $AzureVMName ."
$AzVM | Start-AzVM | Out-Null

# Get Subscription of VM, turn into string, get first 8 characters for suffix
$SubID = $AzVM.Id.Split('/')[-7]
$KVSuffix = $SubID.Substring(0,8)

# generate expected name for KV if none provided via parameter
if(!$EncryptKVName){ # Generate name, uses first 8 character of subscription as UID
    $KVName = "vm-encrypt-kv-$KVSuffix"
    Write-Output "INFO: No custom Keyvault Specified. Using default auto-generated KV Name: $KVName"
}
else { # use Keyvault Name provided
    $KVName = $EncryptKVName
    Write-Output "INFO: Existing Keyvault Specified: $KVName"
}

# Search for keyvault using $KVName
Write-Output "INFO: Searching for Keyvault $KVName . . ."
$KVSearch = Get-AzKeyVault -VaultName $KVName

if(!$KVSearch){ # create keyvault (if none existing) and enable encryption
    Write-Output "INFO: Keyvault not found. Creating new KeyVault: $KVName"

    $NewKV = New-AzKeyVault `
        -VaultName $KVName `
        -ResourceGroupName $AzVM.ResourceGroupName `
        -Location $AzVM.Location `
        -EnabledForDiskEncryption

    Write-Output "INFO: Setting OSDisk for Encryption. . ." 
    Set-AzVMDiskEncryptionExtension `
        -ResourceGroupName $AzVM.ResourceGroupName `
        -VMName $AzureVMName `
        -DiskEncryptionKeyVaultUrl $NewKV.VaultUri `
        -DiskEncryptionKeyVaultId $NewKV.ResourceId `
        -Force
}
else { # use pre-existing keyvault
    Write-Output "INFO: Pre-existing keyvault $KVName found. Continuing with this Keyvault"
    $ExistingKV = Get-AzKeyVault -VaultName $KVName
    
    if($true -eq $ExistingKV.EnabledForDiskEncryption){
        Write-Output "INFO: Setting OSDisk for Encryption. . . " 
        Set-AzVMDiskEncryptionExtension `
            -ResourceGroupName $AzVM.ResourceGroupName `
            -VMName $AzureVMName `
            -DiskEncryptionKeyVaultUrl $ExistingKV.VaultUri `
            -DiskEncryptionKeyVaultId $ExistingKV.ResourceId `
            -Force
    }
    else{
        Write-Output "ERROR: Keyvault $KVName is not enabled for disk encryption.
       See: https://docs.microsoft.com/en-us/azure/virtual-machines/windows/disk-encryption-key-vault#set-key-vault-advanced-access-policies"
        Write-Error "ERROR: Keyvault $KVName is not enabled for disk encryption.
       See: https://docs.microsoft.com/en-us/azure/virtual-machines/windows/disk-encryption-key-vault#set-key-vault-advanced-access-policies" `
       -ErrorAction Stop
    }
}

# Give Encryption Process 90 seconds to show result
Write-Output "INFO: Waiting 90 Seconds for Encryption Status to update. . ."
Start-Sleep -Seconds 90

# Verify process complete
Write-Output "INFO: Checking status of Encryption. . . "
$report = Get-AzVmDiskEncryptionStatus -VMName $AzVM.Name -ResourceGroupName $AzVM.ResourceGroupName
if($report.OsVolumeEncrypted -notmatch "NotEncrypted"){
    Write-Output "INFO: OSDisk is Encrypted."
}
else {
    Write-Output "ERROR: OSDisk did not sucessfully encrypt."
    Write-Error "ERROR: OSDisk did not sucessfully encrypt." -ErrorAction Stop
}
