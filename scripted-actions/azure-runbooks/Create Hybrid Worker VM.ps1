#description: Create a new vm in the specified vnet and enable is as a hybrid worker for the Nerdio automation account 
#tags: Nerdio, Preview

<# Notes:

#>

<# Variables:
{
  "VnetName": {
    "Description": "VNet for the hybrind worker vm",
    "IsRequired": true
  },
  "VnetResourceGroup": {
    "Description": "Resource group of the VNet",
    "IsRequired": true
  },
  "SubnetName": {
    "Description": "Subnet for the hybrind worker vm",
    "IsRequired": true
  },
  "HybridWorkerVMName": {
    "Description": "Name of new hybrid worker VM. Must be fewer than 15 characters.",
    "IsRequired": true,
    "DefaultValue": "nerdio-hw-vm"
  },
  "HybridWorkerGroupName": {
    "Description": "Name of new hybrid worker group created in the Azure automation account",
    "IsRequired": true,
    "DefaultValue": "nerdio-hybridworker-group"
  },
  "VMResourceGroup": {
    "Description": "Resource group for the new vm. If not specified, rg of Nerdio Manager will be used.",
    "IsRequired": false
  },
  "VMSize": {
    "Description": "Size of hybrid worker VM",
    "IsRequired": false,
    "DefaultValue": "Standard_D2s_v3"
  },
  "UseAzureHybridBenefit": {
    "Description": "Use AHB if you have a Software Assurance-enabled Windows Server license",
    "IsRequired": false,
    "DefaultValue": "false"
  }
}
#>

$ErrorActionPreference = 'Stop'

$Prefix = ($KeyVaultName -split '-')[0]
$NMEIdString = ($KeyVaultName -split '-')[3]
$NMEAppName = "$Prefix-app-$NMEIdString"
$AppServicePlanName = "$Prefix-app-plan-$NMEIdString"
$KeyVault = Get-AzKeyVault -VaultName $KeyVaultName
$Context = Get-AzContext
$NMESubscriptionName = $context.Subscription.Name
$NMESubscriptionId = $context.Subscription.Id
$NMEResourceGroupName = $KeyVault.ResourceGroupName
$NMERegionName = $KeyVault.Location


##### Optional Variables #####

#Define the following parameters for the temp vm
$vmAdminUsername = "LocalAdminUser"
$vmAdminPassword = ConvertTo-SecureString "LocalAdminP@sswordHere" -AsPlainText -Force
$vmComputerName = $HybridWorkerVMName
 
#Define the following parameters for the Azure resources.
$azureVmOsDiskName = "$HybridWorkerVMName"
 
#Define the networking information.
$azureNicName = "$HybridWorkerVMName"
#$azurePublicIpName = "$HybridWorkerVMName-IP"
 
 
#Define the VM marketplace image details.
$azureVmPublisherName = "MicrosoftWindowsServer"
$azureVmOffer = "WindowsServer"
$azureVmSkus = "2019-datacenter-core-g2"

$Vnet = Get-AzVirtualNetwork -Name $VnetName -ResourceGroupName $VnetResourceGroup

if ([string]::IsNullOrEmpty($VMResourceGroup)) {
    $VMResourceGroup = $vnet.ResourceGroupName
}

$azureLocation = $Vnet.Location

if ($UseAzureHybridBenefit -eq $true) {
    $LicenseType = 'Windows_Server'
}
else {
    $LicenseType = 'Windows_Client'
}

$LAW = Get-AzOperationalInsightsWorkspace -Name "$Prefix-app-law-$NMEIdString" -ResourceGroupName $NMEResourceGroupName

##### Script Logic #####

#Get the subnet details for the specified virtual network + subnet combination.
Write-Output "Getting subnet details"
$Subnet = ($Vnet).Subnets | Where-Object {$_.Name -eq $SubnetName}
 
#Create the public IP address.
#Write-Output "Creating public ip"
#$azurePublicIp = New-AzPublicIpAddress -Name $azurePublicIpName -ResourceGroupName $azureResourceGroup -Location $azureLocation -AllocationMethod Dynamic
 
#Create the NIC and associate the public IpAddress.
Write-Output "Creating NIC"
$azureNIC = New-AzNetworkInterface -Name $azureNicName -ResourceGroupName $VMResourceGroup -Location $azureLocation -SubnetId $Subnet.Id 
 
#Store the credentials for the local admin account.
Write-Output "Creating VM credentials"
$vmCredential = New-Object System.Management.Automation.PSCredential ($vmAdminUsername, $vmAdminPassword)
 
#Define the parameters for the new virtual machine.
Write-Output "Creating VM config"
$VirtualMachine = New-AzVMConfig -VMName $HybridWorkerVMName -VMSize $VMSize -LicenseType $LicenseType
$VirtualMachine = Set-AzVMOperatingSystem -VM $VirtualMachine -Windows -ComputerName $vmComputerName -Credential $vmCredential -ProvisionVMAgent -EnableAutoUpdate
$VirtualMachine = Add-AzVMNetworkInterface -VM $VirtualMachine -Id $azureNIC.Id
$VirtualMachine = Set-AzVMSourceImage -VM $VirtualMachine -PublisherName $azureVmPublisherName -Offer $azureVmOffer -Skus $azureVmSkus -Version "latest" 
$VirtualMachine = Set-AzVMBootDiagnostic -VM $VirtualMachine -Disable
$VirtualMachine = Set-AzVMOSDisk -VM $VirtualMachine -StorageAccountType "StandardSSD_LRS" -Caching ReadWrite -Name $azureVmOsDiskName -CreateOption FromImage
 
#Create the virtual machine.
Write-Output "Creating new VM"
$VM = New-AzVM -ResourceGroupName $azureResourceGroup -Location $azureLocation -VM $VirtualMachine -Verbose -ErrorAction stop

