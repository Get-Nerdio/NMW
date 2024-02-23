#description: Enable Trusted Launch on an existing VM
#tags: Nerdio, Preview

<# Notes:

This Scripted Action will enable Trusted Launch on an existing VM. It will also enable 
Secure Boot and Virtual TPM, unless the variables $EnableSecureBoot and $EnableVtpm are 
set to $false.

This script validates that the VM is a Gen 2 VM and that it is not already in Trusted Launch,
but it does not validate that the VM is in a state where Trusted Launch can be enabled. It is
best practice to ensure the VM is backed up before enabling Trusted Launch. See

https://learn.microsoft.com/en-us/azure/virtual-machines/trusted-launch-existing-vm?tabs=portal

for more information on best practices for enabling Trusted Launch.

This script requires the Az modules, which may need to be updated in the scripted actions 
automation account in order for the script to run successfully.

#>

$EnableSecureBoot = $true
$EnableVtpm = $true

$ErrorActionPreference = 'Stop'

$VMStatus = Get-AzVM -ResourceGroupName $AzureResourceGroupName -Name $AzureVMName -Status

# check if the VM is already in trusted launch
$VMInfo = Get-AzVM -ResourceGroupName $AzureResourceGroupName -VMName $AzureVMName
if (($vminfo).SecurityProfile.SecurityType -eq "TrustedLaunch") {
    Write-Output "VM is already TrustedLaunch"
    Exit
}

# check if the VM is gen 2
if ($VMStatus.HyperVGeneration -ne "V2") {
    Throw "VM is not Gen 2. TrustedLaunch is currently only supported on Gen 2 VMs."
    Exit
}

if ($VMStatus.statuses.displaystatus -notcontains 'VM deallocated') {
    Write-Output "Stopping VM"
    Stop-AzVM -ResourceGroupName $AzureResourceGroupName -Name $AzureVMName -Force
}
# stop vm
Write-Output "Stopping VM"
Stop-AzVM -ResourceGroupName $AzureResourceGroupName -Name $AzureVMName -Force

# enable trusted launch
Write-Output "Enabling TrustedLaunch"
try {
    $VMInfo | Update-AzVM -SecurityType TrustedLaunch  -EnableSecureBoot $EnableSecureBoot -EnableVtpm $EnableVtpm
}
catch {
    Throw "Failed to enable TrustedLaunch. You may need to update the Az.Compute in the scripted actions automation account to the latest version."
    throw $_
}

if ($VMStatus.statuses.displaystatus -notcontains 'VM deallocated') {
    Write-Output "Starting VM"
    Start-AzVM -ResourceGroupName $AzureResourceGroupName -Name $AzureVMName
}