#description: (PREVIEW) Creates a temp vm which is used to shrink FSLogix profiles
#tags: Nerdio, Preview

<#
Notes:
This script creates a temporary VM and then runs FSLogix-ShrinkDisk.ps1 to reduce the size of the 
FSLogix VHD(X) files. After completing, the temporary VM is deleted.

You must provide some variables to this script to determine where the temporary VM is created, and
how it will access the fileshare. You can provide these variables as parameters when running the
script, or as Secure Variables created in Nerdio Manager under Settings->Nerdio Integrations. 

This script requires credentials to acccess the fileshare. These can be passed as AD credentials
when running the script (check the "Pass AD credentials" box when running the script), or as 
Secure Variables. You must ensure the user has been granted access to the fileshare. Alternately,
if using Azure Files you may use the storage account user and key

If using Secure Variables, the variables to create in Nerdio Manager are:
  FslResourceGroup - the resource group in which the temp vm will be created. 
  FslTempVmVnet - the vnet in which the temp vm will be created
  FslTempVmSubnet - the subnet in which the temp vm will be created
  FslStorageUser - Storage account key user, or AD user with access to fileshare
  FslStorageKey - Storage account key, or AD password
  FslFileshare - UNC path to the fslogix profiles share

To adjust other variables, clone this scripted action and adjust to your requirements

The Invoke-FslShrinkDisk script used here was written by Jim Moyle.
See https://github.com/FSLogix/Invoke-FslShrinkDisk/blob/master/Invoke-FslShrinkDisk.ps1 for more 
information on the FSLogix-ShrinkDisk.ps1 script and arguments you can pass to it.

To adjust the arguments passed to FSLogix-ShrinkDisk.ps1, use the AdditionalShrinkDiskParameters
when running this script.

#>

<# Variables:
{
  "VNetName": {
    "Description": "VNet in which to create the temp VM. Must be able to access the fslogix fileshare.",
    "IsRequired": false
  },
  "SubnetName": {
    "Description": "Subnet in which to create the temp VM.",
    "IsRequired": false
  },
  "FileSharePath": {
    "Description": "UNC path e.g. \\\\storageaccount.file.core.windows.net\\premiumfslogix01",
    "IsRequired": false
  },
  "TempVmResourceGroup": {
    "Description": "Resource group in which to create the temp vm. If not supplied, resource group of vnet will be used.",
    "IsRequired": false
  },
  "AdditionalShrinkDiskParameters": {
    "Description": "parameters to send to the FSLogix-ShrinkDisk.ps1 script. E.g: -DeleteOlderThanDays 90 -IgnoreLessThanGB 5",
    "IsRequired": false
  }
}
#>

# Adjust Variables below to alter to your preference:

$ErrorActionPreference = 'Stop'


##### Required Variables #####


$AzureRegionName = $SecureVars.FslRegion
$AzureVMName = "fslshrink-tempvm"
$azureVmSize = "Standard_D8s_v3"
$azureVnetName = $SecureVars.FslTempVmVnet
$azureVnetSubnetName = $SecureVars.FslTempVmSubnet

#Define the storage account for the fslogix share
$StorageAccountUser = $SecureVars.FslStorageUser # Storage account key user, usually same as storage account name
$StorageAccountKey = $SecureVars.FslStorageKey # Storage account key
$FSLogixFileShare = $SecureVars.FslFileShare # in UNC path e.g. \\storageaccount.file.core.windows.net\premiumfslogix01

# Override SecureVars values with parameters supplied at runtime, if specified
if ($VNetName) {
  $azureVnetName = $VNetName
}
if ($SubnetName) {
  $azureVnetSubnetName = $SubnetName
}
if ($FileSharePath) {
  $FSLogixFileShare = $FileSharePath
}
if ($ADUsername) {
  $StorageAccountUser = $ADUsername
}
if ($ADPassword) {
  $StorageAccountKey = $ADPassword
}
if ($TempVmResourceGroup) {
  $azureResourceGroup = $TempVmResourceGroup
}

$FSLogixLogFile = "C:\Windows\Temp\FslShrinkDisk.log"
$InvokeFslShrinkCommand = "FSLogix-ShrinkDisk.ps1 -Path $FSLogixFileShare -Recurse -LogFilePath $FSLogixLogFile $AdditionalShrinkDiskParameters -PassThru"

Write-Output "Variables set: 
VNet for temp vm is $azureVnetName
Subnet is $azureVnetSubnetName
Path to fslogix share is $FSLogixFileShare
User account to access share is $StorageAccountUser
Resource Group for temp vm is $azureResourceGroup"

##### Optional Variables #####

#Define the following parameters for the temp vm
$vmAdminUsername = "LocalAdminUser"
$vmAdminPassword = ConvertTo-SecureString "LocalAdminP@sswordHere" -AsPlainText -Force
$vmComputerName = "fslshrink-tmp"
 
#Define the parameters for the Azure resources.
$azureVmOsDiskName = "$AzureVMName-os"
 
#Define the networking information.
$azureNicName = "$azureVmName-NIC"
$azurePublicIpName = "$azureVmName-IP"
 
#Define the VM marketplace image details.
$azureVmPublisherName = "MicrosoftWindowsServer"
$azureVmOffer = "WindowsServer"
$azureVmSkus = "2019-datacenter-core-g2"

##### Script Logic #####

# Check for essential variables

if ([string]::IsNullOrEmpty($azureVnetName)){
  Throw "Missing vnet name. Either provide the VNetName parameter at runtime, or create the FslTempVmVnet secure variable in Nerdio Settings"
}
if ([string]::IsNullOrEmpty($azureVnetSubnetName)) {
  Throw "Missing subnet name. Either provide the SubnetName parameter at runtime, or create the FslTempVmSubnet secure variable in Nerdio Settings."
}
if ([string]::IsNullOrEmpty($FSLogixFileShare)) {
  Throw "Missing the FSLogix Fileshare. Either provide the FileSharePath parameter at runtime, or create the FslFileshare secure variable in Nerdio Settings."
}
if ([string]::IsNullOrEmpty($StorageAccountUser) -or [string]::IsNullOrEmpty($StorageAccountKey)) {
  Throw "Missing credentials. Please pass AD credentials when running this scripted action, or create FslStorageUser and FslStorageKey secure variables in Nerdio Manager"
}

#Get the subnet details for the specified virtual network + subnet combination.
Write-Output "Getting vnet details"
$Vnet = Get-AzVirtualNetwork -Name $azureVnetName

# use resource group of vnet if not specified in parameters or securevars
if ([string]::IsNullOrEmpty($AzureResourceGroup)) {
  $AzureResourceGroup = $Vnet.ResourceGroupName
}
$AzureRegionName = $vnet.Location
$azureVnetSubnet = $Vnet.Subnets | Where-Object {$_.Name -eq $azureVnetSubnetName}
Write-Output "Region is $($vnet.Location)"

Try {
  #Create the public IP address.
  Write-Output "Creating public ip"
  $azurePublicIp = New-AzPublicIpAddress -Name $azurePublicIpName -ResourceGroupName $azureResourceGroup -Location $AzureRegionName -AllocationMethod Dynamic
 
  #Create the NIC and associate the public IpAddress.
  Write-Output "Creating NIC"
  $azureNIC = New-AzNetworkInterface -Name $azureNicName -ResourceGroupName $azureResourceGroup -Location $AzureRegionName -SubnetId $azureVnetSubnet.Id -PublicIpAddressId $azurePublicIp.Id
  
  #Store the credentials for the local admin account.
  Write-Output "Creating VM credentials"
  $vmCredential = New-Object System.Management.Automation.PSCredential ($vmAdminUsername, $vmAdminPassword)
  
  #Define the parameters for the new virtual machine.
  Write-Output "Creating VM config"
  $VirtualMachine = New-AzVMConfig -VMName $azureVmName -VMSize $azureVmSize
  $VirtualMachine = Set-AzVMOperatingSystem -VM $VirtualMachine -Windows -ComputerName $vmComputerName -Credential $vmCredential -ProvisionVMAgent -EnableAutoUpdate
  $VirtualMachine = Add-AzVMNetworkInterface -VM $VirtualMachine -Id $azureNIC.Id
  $VirtualMachine = Set-AzVMSourceImage -VM $VirtualMachine -PublisherName $azureVmPublisherName -Offer $azureVmOffer -Skus $azureVmSkus -Version "latest"
  $VirtualMachine = Set-AzVMBootDiagnostic -VM $VirtualMachine -Disable
  $VirtualMachine = Set-AzVMOSDisk -VM $VirtualMachine -StorageAccountType "Premium_LRS" -Caching ReadWrite -Name $azureVmOsDiskName -CreateOption FromImage
  
  #Create the virtual machine.
  Write-Output "Creating new VM"
  $VM = New-AzVM -ResourceGroupName $azureResourceGroup -Location $AzureRegionName -VM $VirtualMachine -Verbose -ErrorAction stop


  $azurePublicIp = Get-AzPublicIpAddress -Name $azurePublicIpName -ResourceGroupName $AzureResourceGroup
  $ScriptBlock = @"
  Try {
    Invoke-Expression "net use $FSLogixFileShare /user:$StorageAccountUser $StorageAccountKey"
    Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/FSLogix/Invoke-FslShrinkDisk/master/Invoke-FslShrinkDisk.ps1' -OutFile 'C:\Windows\Temp\FSLogix-ShrinkDisk.ps1' -usebasicparsing -ea Stop
    Invoke-Expression "C:\Windows\Temp\$InvokeFslShrinkCommand"
    import-csv -Path $FSLogixLogFIle
  }
  catch {
  "[`$(`$_.Exception.GetType().FullName)]" | Out-File C:\Windows\Temp\FslShrinkDisk.log -append
    # Error MESSAGE
    `$_.Exception.Message | Out-File C:\Windows\Temp\FslShrinkDisk.log -append
    Throw `$_
  }
"@


  $scriptblock > .\scriptblock.ps1

  Write-Output "Running shrink script on temp vm"

  $results = Invoke-AzVmRunCommand -ResourceGroupName $azureResourceGroup -VMName $azureVmName -ScriptPath .\scriptblock.ps1 -CommandId 'RunPowershellScript'

  $results | Out-String | Write-Output
}
Catch {
  Write-Output "Error during execution of script on temp VM"
  Write-Error $_ 
}

Finally {
  "Removing temporary VM" | Write-Output
  Remove-AzVM -Name $azureVmName -ResourceGroupName $AzureResourceGroup -Force -ErrorAction Continue
  Remove-AzDisk -ResourceGroupName $AzureResourceGroup -DiskName $azureVmOsDiskName -Force -ErrorAction Continue
  Remove-AzNetworkInterface -Name $azureNicName -ResourceGroupName $AzureResourceGroup -Force -ErrorAction Continue
  Remove-AzPublicIpAddress -Name $azurePublicIpName -ResourceGroupName $AzureResourceGroup -Force -ErrorAction Continue
}
