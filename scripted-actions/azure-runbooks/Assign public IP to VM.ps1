#description: Creates and associated a public IP address to each session host VM.
#tags: Nerdio
<#
Notes:
This script assigns a Public IP to a VM.
If it hasn't run before, it will create a public IP based on the name of the VM, and then assign it
to the default NIC of the VM. If there is an existing Public IP created by 
this script, then the existing public IP will be associated instead.

Important: VM must have one NIC (default setup), and these public IPs must be deleted separately after
the VM is deleted. Nerdio will NOT remove public IPs automatically. Removing the public IP is
only necessary if the vm is being deleted, and the name will not be used in the future or
public IPs will no longer be needed.
#>


# Ensure context is using correct subscription
Set-AzContext -SubscriptionId $AzureSubscriptionId | Out-Null

# Query for Azure VM object using $AzureVMName parameter, pass into $AzVM
$AzVM = Get-AzVM -Name $AzureVMName -ResourceGroupName $AzureResourceGroupName

# Query for NIC attached to VM, pass into $NIC
$NIC =  Get-AzNetworkInterface -resourceID $AzVM.NetworkProfile.NetworkInterfaces.Id

# Query for Subnet, pass into $subnet
$Subnet = Get-AzVirtualNetworkSubnetConfig -ResourceID $NIC.IpConfigurations.Subnet.Id

# Detect if Public IP already Associated with VM
if($NIC.IpConfigurations.PublicIPAddress)
{
    Write-Output "INFO: This VM is already associated with a Public IP Address. No action needed, stopping script."
    exit
}

# Check if publicIP was made for this VM previously (Previous VM may have been deleted; PubIP was then orphaned)
$CheckPubIPName = Get-AzPublicIPAddress -Name "$AzureVMName-ip"
if(!$CheckPubIPName){
    # Create the Public IP Azure resource if there are none existing
    Write-Output "INFO: No previous Public IP found. Creating new Public iP"
    $NewPubIPParams = @{
        Name = "$AzureVMName-ip"
        ResourceGroupName = $AzVM.ResourceGroupName
        AllocationMethod = 'static'
        Location = $AzVM.Location
        Sku = 'Standard'
        Zone = $AzVM.Zones
    }
    $PubIP = New-AzPublicIpAddress @NewPubIPParams -ErrorAction Stop
}
else{ 
    # If there was an existing public IP, pass the result along to be associated
    Write-Output "INFO: Previously created Public IP found. Continuing with existing Public IP"
    $PubIP = $CheckPubIPName
}

# Associate newly created public IP with the NIC attached to the VM
Write-Output "INFO: Associating Public IP with VM"
$NIC | Set-AzNetworkInterfaceIpConfig -Name $NIC.IpConfigurations.Name -PublicIPAddress $PubIP -Subnet $Subnet | Out-Null
# Set the interface to finalize change
Write-Output "INFO: Setting NIC Interface to finalize changes. . ."
$NIC | Set-AzNetworkInterface | Out-Null


$VerifyIP = Get-AzPublicIPAddress -Name "$AzureVMName-ip"
$PubIPAddress = $VerifyIP.IpAddress
if($NIC.IpConfigurations.PublicIPAddress)
{
    Write-Output "INFO: VM has been assigned a Public IP successfully. IP Address: $PubIPAddress"
}
else {
    Write-Output 'ERROR: VM was not assigned a public IP Address'
    Write-Error 'ERROR: VM was not assigned a public IP Address' -ErrorAction Stop

}
