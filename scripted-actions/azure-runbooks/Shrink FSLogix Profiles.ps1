#description: (PREVIEW) Creates a temp vm which is used to shrink FSLogix profiles
#tags: Nerdio, Preview

<#
Notes:
This script creates a temporary VM and then runs FSLogix-ShrinkDisk.ps1 to reduce the size of the FSLogix VHD(X) files. 
After completing, the temporary VM is deleted.

You must provide some secure variables to this script as seen in the Required Variables section. 
Set these up in NMW under Settings->Nerdio Integrations.
To adjust other variables, clone this scripted action and adjust to your requirements

The Invoke-FslShrinkDisk script used here was written by Jim Moyle.
See https://github.com/FSLogix/Invoke-FslShrinkDisk/blob/master/Invoke-FslShrinkDisk.ps1 for more 
information on the FSLogix-ShrinkDisk.ps1 script and parameters you can pass to it.
#>

# Adjust Variables below to alter to your preference:

##### Required Variables #####

$AzureResourceGroupName = $SecureVars.FslResourceGroup
$AzureRegionName = $SecureVars.FslRegion
$AzureVMName = "fslshrink-tempvm"
$azureVmSize = "Standard_D8s_v3"
$azureVnetName = $SecureVars.FslTempVmVnet
$azureVnetSubnetName = $SecureVars.FslTempVmSubnet

#Define the storage account for the fslogix share
$StorageAccountUser = $SecureVars.FslStorageUser
$StorageAccountKey = $SecureVars.FslStorageKey 
$FSLogixFileShare = $SecureVars.FslFileShare # e.g. \\storageaccount.file.core.windows.net\premiumfslogix01\
$FSLogixLogFIle = "C:\Windows\Temp\FslShrinkDisk.log"
$InvokeFslShrinkCommand = "FSLogix-ShrinkDisk.ps1 -Path $FSLogixFileShare -Recurse -LogFilePath $FSLogixLogFIle -PassThru"


##### Optional Variables #####

#Define the following parameters for the temp vm
$vmAdminUsername = "LocalAdminUser"
$vmAdminPassword = ConvertTo-SecureString "LocalAdminP@sswordHere" -AsPlainText -Force
$vmComputerName = "fslshrink-tmp"
 
#Define the following parameters for the Azure resources.
$azureLocation = $AzureRegionName #passed as NMW Scripted Actions variable
$azureResourceGroup = $AzureResourceGroupName #passed as NMW Scripted Actions variable
$azureVmOsDiskName = "$AzureVMName-os"
 
#Define the networking information.
$azureNicName = "$azureVmName-NIC"
$azurePublicIpName = "$azureVmName-IP"
 
 
#Define the VM marketplace image details.
$azureVmPublisherName = "MicrosoftWindowsServer"
$azureVmOffer = "WindowsServer"
$azureVmSkus = "2019-datacenter-core-g2"


##### Script Logic #####


#Get the subnet details for the specified virtual network + subnet combination.
$azureVnetSubnet = (Get-AzVirtualNetwork -Name $azureVnetName -ResourceGroupName $azureResourceGroup).Subnets | Where-Object {$_.Name -eq $azureVnetSubnetName}
 
#Create the public IP address.
$azurePublicIp = New-AzPublicIpAddress -Name $azurePublicIpName -ResourceGroupName $azureResourceGroup -Location $azureLocation -AllocationMethod Dynamic
 
#Create the NIC and associate the public IpAddress.
$azureNIC = New-AzNetworkInterface -Name $azureNicName -ResourceGroupName $azureResourceGroup -Location $azureLocation -SubnetId $azureVnetSubnet.Id -PublicIpAddressId $azurePublicIp.Id
 
#Store the credentials for the local admin account.
$vmCredential = New-Object System.Management.Automation.PSCredential ($vmAdminUsername, $vmAdminPassword)
 
#Define the parameters for the new virtual machine.
$VirtualMachine = New-AzVMConfig -VMName $azureVmName -VMSize $azureVmSize
$VirtualMachine = Set-AzVMOperatingSystem -VM $VirtualMachine -Windows -ComputerName $vmComputerName -Credential $vmCredential -ProvisionVMAgent -EnableAutoUpdate
$VirtualMachine = Add-AzVMNetworkInterface -VM $VirtualMachine -Id $azureNIC.Id
$VirtualMachine = Set-AzVMSourceImage -VM $VirtualMachine -PublisherName $azureVmPublisherName -Offer $azureVmOffer -Skus $azureVmSkus -Version "latest"
$VirtualMachine = Set-AzVMBootDiagnostic -VM $VirtualMachine -Disable
$VirtualMachine = Set-AzVMOSDisk -VM $VirtualMachine -StorageAccountType "Premium_LRS" -Caching ReadWrite -Name $azureVmOsDiskName -CreateOption FromImage
 
#Create the virtual machine.
$VM = New-AzVM -ResourceGroupName $azureResourceGroup -Location $azureLocation -VM $VirtualMachine -Verbose -ErrorAction stop
$azurePublicIp = Get-AzPublicIpAddress -Name $azurePublicIpName -ResourceGroupName $AzureResourceGroupName


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
  Throw $_
}
"@


$scriptblock > .\scriptblock.ps1

Invoke-AzVmRunCommand -ResourceGroupName $AzureResourceGroupName -VMName $azureVmName -ScriptPath .\scriptblock.ps1 -CommandId 'RunPowershellScript'

Remove-AzVM -Name $azureVmName -ResourceGroupName $AzureResourceGroupName -Force
Remove-AzDisk -ResourceGroupName $AzureResourceGroupName -DiskName $azureVmOsDiskName -Force
Remove-AzNetworkInterface -Name $azureNicName -ResourceGroupName $AzureResourceGroupName -Force
Remove-AzPublicIpAddress -Name $azurePublicIpName -ResourceGroupName $AzureResourceGroupName -Force
