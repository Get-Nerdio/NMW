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
$azureVmOsDiskName = "$HybridWorkerVMName-osdisk"
 
#Define the networking information.
$azureNicName = "$HybridWorkerVMName-nic"
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
$VirtualMachine = New-AzVMConfig -VMName $HybridWorkerVMName -VMSize $VMSize -LicenseType $LicenseType -IdentityType SystemAssigned
$VirtualMachine = Set-AzVMOperatingSystem -VM $VirtualMachine -Windows -ComputerName $vmComputerName -Credential $vmCredential -ProvisionVMAgent -EnableAutoUpdate
$VirtualMachine = Add-AzVMNetworkInterface -VM $VirtualMachine -Id $azureNIC.Id
$VirtualMachine = Set-AzVMSourceImage -VM $VirtualMachine -PublisherName $azureVmPublisherName -Offer $azureVmOffer -Skus $azureVmSkus -Version "latest" 
$VirtualMachine = Set-AzVMBootDiagnostic -VM $VirtualMachine -Disable
$VirtualMachine = Set-AzVMOSDisk -VM $VirtualMachine -StorageAccountType "StandardSSD_LRS" -Caching ReadWrite -Name $azureVmOsDiskName -CreateOption FromImage
 
#Create the virtual machine.
Write-Output "Creating new VM"
$VM = New-AzVM -ResourceGroupName $VMResourceGroup -Location $azureLocation -VM $VirtualMachine -Verbose -ErrorAction stop
$VM = get-azvm -ResourceGroupName $VMResourceGroup -Name $HybridWorkerVMName

$AA = Get-AzAutomationAccount -ResourceGroupName $NMEResourceGroupName | Where-Object AutomationAccountName -Match 'runbooks'

Set-AzKeyVaultAccessPolicy -VaultName $keyvaultName -ObjectId $vm.Identity.PrincipalId -PermissionsToSecrets get 


$cert = Get-AzKeyVaultCertificate -VaultName $KeyVaultName -name "$Prefix-automation-cert"
$secret = Get-AzKeyVaultSecret -VaultName $keyvaultName -Name $cert.Name
$secretByte = [Convert]::FromBase64String(($secret.SecretValue | ConvertFrom-SecureString -AsPlainText))


#"Install-Script -Name New-OnPremiseHybridWorker -Force" > .\hw-script.ps1

#$InstallHwScript = Invoke-AzVMRunCommand -ResourceGroupName $VMResourceGroup -VMName $HybridWorkerVMName -CommandId 'RunPowerShellScript' -ScriptPath .\hw-script.ps1

$ClientSecret = Get-AzKeyVaultSecret -VaultName $keyvaultName -Name 'AzureAD--ClientSecret' -AsPlainText
$azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
$profileClient = New-Object -TypeName Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient -ArgumentList ($azProfile)
$token = $profileClient.AcquireAccessToken($context.Subscription.TenantId)
$authHeader = @{
   'Content-Type'='application/json'
   'Authorization'='Bearer ' + $token.AccessToken
}

# Get automation hybrid service url
$Response = Invoke-WebRequest "https://westcentralus.management.azure.com/subscriptions/$($context.subscription.id)/resourceGroups/$NMEResourceGroupName/providers/Microsoft.Automation/automationAccounts/$($AA.AutomationAccountName)?api-version=2021-06-22" -Headers $authHeader
$AAProperties =  ($response.Content | ConvertFrom-Json).properties
$AutomationHybridServiceUrl = $AAProperties.automationHybridServiceUrl

$settings = @{
  "AutomationAccountURL"  = "$AutomationHybridServiceUrl"
}

Set-AzVMExtension -ResourceGroupName $VMResourceGroup -Location $azureLocation -VMName $HybridWorkerVMName -Name "HybridWorkerExtension" -Publisher "Microsoft.Azure.Automation.HybridWorker" -ExtensionType HybridWorkerForWindows -TypeHandlerVersion 0.1 -Settings $settings -AsJob 







automationAccount automationAccountLocation workerGroupName virtualMachineName adminUsername adminPassword vmLocation vmSize osVersion dnsNameForPublicIP
$ArmTemplate = @"
{
  "`$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "nicName": {
      "type": "string"
    },
    "addressPrefix": {
      "type": "string"
    },
    "subnetName": {
      "type": "string"
    },
    "subnetPrefix": {
      "type": "string"
    },
    "virtualNetworkName": {
      "type": "string"
    },
    "publicIPAddressName": {
      "type": "string"
    },
    "networkSecurityGroupName": {
      "type": "string"
    },
    "automationAccount": {
      "type": "string"
    },
    "automationAccountLocation": {
      "type": "string"
    },
    "workerGroupName": {
      "type": "string"
    },
    "virtualMachineName": {
      "type": "string",
      "defaultValue": "simple-vm",
      "metadata": {
        "description": "Name of the virtual machine."
      }
    },
    "adminUsername": {
      "type": "string",
      "metadata": {
        "description": "Username for the Virtual Machine."
      }
    },
    "adminPassword": {
      "type": "securestring",
      "minLength": 12,
      "metadata": {
        "description": "Password for the Virtual Machine."
      }
    },
    "vmLocation": {
      "type": "string",
      "defaultValue": "North Central US",
      "metadata": {
        "description": "Location for the VM."
      }
    },
    "vmSize": {
      "type": "string",
      "defaultValue": "Standard_DS1_v2",
      "metadata": {
        "description": "Size of the virtual machine."
      }
    },
    "osVersion": {
      "type": "string",
      "defaultValue": "2019-Datacenter",
      "allowedValues": [
        "2008-R2-SP1",
        "2012-Datacenter",
        "2012-R2-Datacenter",
        "2016-Nano-Server",
        "2016-Datacenter-with-Containers",
        "2016-Datacenter",
        "2019-Datacenter",
        "2019-Datacenter-Core",
        "2019-Datacenter-Core-smalldisk",
        "2019-Datacenter-Core-with-Containers",
        "2019-Datacenter-Core-with-Containers-smalldisk",
        "2019-Datacenter-smalldisk",
        "2019-Datacenter-with-Containers",
        "2019-Datacenter-with-Containers-smalldisk"
      ],
      "metadata": {
        "description": "The Windows version for the VM. This will pick a fully patched image of this given Windows version."
      }
    },
    "dnsNameForPublicIP": {
      "type": "string",
      "metadata": {
        "description": "DNS name for the public IP"
      }
    },
    "_CurrentDateTimeInTicks": {
      "type": "string",
      "defaultValue": "[utcNow('yyyy-MM-dd')]"
    }
  },
  "variables": {
    "subnetRef": "[resourceId('Microsoft.Network/virtualNetworks/subnets', parameters('virtualNetworkName'), parameters('subnetName'))]",
    "vmName": "[parameters('virtualMachineName')]",
    "UniqueStringBasedOnTimeStamp": "[uniqueString(deployment().name, parameters('_CurrentDateTimeInTicks'))]"
  },
  "resources": [
    {
      "apiVersion": "2020-08-01",
      "type": "Microsoft.Network/publicIPAddresses",
      "name": "[parameters('publicIPAddressName')]",
      "location": "[parameters('vmLocation')]",
      "properties": {
        "publicIPAllocationMethod": "Dynamic",
        "dnsSettings": {
          "domainNameLabel": "[parameters('dnsNameForPublicIP')]"
        }
      }
    },
    {
      "apiVersion": "2020-08-01",
      "type": "Microsoft.Network/networkInterfaces",
      "name": "[parameters('nicName')]",
      "location": "[parameters('vmLocation')]",
      "dependsOn": [
        "[parameters('publicIPAddressName')]",
        "[variables('virtualNetworkName')]"
      ],
      "properties": {
        "ipConfigurations": [
          {
            "name": "ipconfig1",
            "properties": {
              "privateIPAllocationMethod": "Dynamic",
              "publicIPAddress": {
                "id": "[resourceId('Microsoft.Network/publicIPAddresses',parameters('publicIPAddressName'))]"
              },
              "subnet": {
                "id": "[variables('subnetRef')]"
              }
            }
          }
        ]
      }
    },
    {
      "apiVersion": "2020-12-01",
      "type": "Microsoft.Compute/virtualMachines",
      "name": "[variables('vmName')]",
      "location": "[parameters('vmLocation')]",
      "dependsOn": [
        "[parameters('nicName')]"
      ],
      "identity": {
             "type": "SystemAssigned"
      } ,
      "properties": {
        "hardwareProfile": {
          "vmSize": "[parameters('vmSize')]"
        },
        "osProfile": {
          "computerName": "[variables('vmName')]",
          "adminUsername": "[parameters('adminUsername')]",
          "adminPassword": "[parameters('adminPassword')]"
        },
        "storageProfile": {
          "imageReference": {
            "publisher": "MicrosoftWindowsServer",
            "offer": "WindowsServer",
            "sku": "[parameters('osVersion')]",
            "version": "latest"
          },
          "osDisk": {
            "createOption": "FromImage"
          }
        },
        "networkProfile": {
          "networkInterfaces": [
            {
              "id": "[resourceId('Microsoft.Network/networkInterfaces',parameters('nicName'))]"
            }
          ]
        }
      }
    },
    {
      "type": "Microsoft.Automation/automationAccounts",
      "apiVersion": "2021-06-22",
      "name": "[parameters('automationAccount')]",
      "location": "[parameters('automationAccountLocation')]",
      "properties": {
        "sku": {
          "name": "Basic"
        }
      },
      "resources": [
        {
          "name": "[concat(parameters('workerGroupName'),'/',guid('AzureAutomationJobName', variables('UniqueStringBasedOnTimeStamp')))]",
          "type": "hybridRunbookWorkerGroups/hybridRunbookWorkers",
          "apiVersion": "2021-06-22",
          "dependsOn": [
            "[resourceId('Microsoft.Automation/automationAccounts', parameters('automationAccount'))]",
            "[resourceId('Microsoft.Compute/virtualMachines', variables('vmName'))]"
          ],
          "properties": {
            "vmResourceId": "[resourceId('Microsoft.Compute/virtualMachines', parameters('virtualMachineName'))]"
          }
        }
      ]
    },
    {
      "type": "Microsoft.Compute/virtualMachines/extensions",
      "name": "[concat(parameters('virtualMachineName'),'/HybridWorkerExtension')]",
      "apiVersion": "2020-12-01",
      "location": "[parameters('vmLocation')]",
      "dependsOn": [
        "[resourceId('Microsoft.Automation/automationAccounts', parameters('automationAccount'))]",
        "[resourceId('Microsoft.Compute/virtualMachines', parameters('virtualMachineName'))]"
      ],
      "properties": {
        "publisher": "Microsoft.Azure.Automation.HybridWorker",
        "type": "HybridWorkerForWindows",
        "typeHandlerVersion": "0.1",
        "autoUpgradeMinorVersion": true,
        "settings": {
          "AutomationAccountURL": "[reference(resourceId('Microsoft.Automation/automationAccounts', parameters('automationAccount'))).AutomationHybridServiceUrl]"
        }
      }
    }
  ],
  "outputs": {
    "output1": {
      "type": "string",
      "value": "[reference(resourceId('Microsoft.Automation/automationAccounts', parameters('automationAccount'))).AutomationHybridServiceUrl]"
    }
  }
}
"@

$FullArmTemplate = @"
{
  "`$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "automationAccount": {
      "type": "string"
    },
    "automationAccountLocation": {
      "type": "string"
    },
    "workerGroupName": {
      "type": "string"
    },
    "virtualMachineName": {
      "type": "string",
      "defaultValue": "simple-vm",
      "metadata": {
        "description": "Name of the virtual machine."
      }
    },
    "adminUsername": {
      "type": "string",
      "metadata": {
        "description": "Username for the Virtual Machine."
      }
    },
    "adminPassword": {
      "type": "securestring",
      "minLength": 12,
      "metadata": {
        "description": "Password for the Virtual Machine."
      }
    },
    "vmLocation": {
      "type": "string",
      "defaultValue": "North Central US",
      "metadata": {
        "description": "Location for the VM."
      }
    },
    "vmSize": {
      "type": "string",
      "defaultValue": "Standard_DS1_v2",
      "metadata": {
        "description": "Size of the virtual machine."
      }
    },
    "osVersion": {
      "type": "string",
      "defaultValue": "2019-Datacenter",
      "allowedValues": [
        "2008-R2-SP1",
        "2012-Datacenter",
        "2012-R2-Datacenter",
        "2016-Nano-Server",
        "2016-Datacenter-with-Containers",
        "2016-Datacenter",
        "2019-Datacenter",
        "2019-Datacenter-Core",
        "2019-Datacenter-Core-smalldisk",
        "2019-Datacenter-Core-with-Containers",
        "2019-Datacenter-Core-with-Containers-smalldisk",
        "2019-Datacenter-smalldisk",
        "2019-Datacenter-with-Containers",
        "2019-Datacenter-with-Containers-smalldisk"
      ],
      "metadata": {
        "description": "The Windows version for the VM. This will pick a fully patched image of this given Windows version."
      }
    },
    "dnsNameForPublicIP": {
      "type": "string",
      "metadata": {
        "description": "DNS name for the public IP"
      }
    },
    "_CurrentDateTimeInTicks": {
      "type": "string",
      "defaultValue": "[utcNow('yyyy-MM-dd')]"
    }
  },
  "variables": {
    "nicName": "myVMNict",
    "addressPrefix": "10.0.0.0/16",
    "subnetName": "Subnet",
    "subnetPrefix": "10.0.0.0/24",
    "subnetRef": "[resourceId('Microsoft.Network/virtualNetworks/subnets', variables('virtualNetworkName'), variables('subnetName'))]",
    "vmName": "[parameters('virtualMachineName')]",
    "virtualNetworkName": "MyVNETt",
    "publicIPAddressName": "myPublicIPt",
    "networkSecurityGroupName": "default-NSGt",
    "UniqueStringBasedOnTimeStamp": "[uniqueString(deployment().name, parameters('_CurrentDateTimeInTicks'))]"
  },
  "resources": [
    {
      "apiVersion": "2020-08-01",
      "type": "Microsoft.Network/publicIPAddresses",
      "name": "[parameters('publicIPAddressName')]",
      "location": "[parameters('vmLocation')]",
      "properties": {
        "publicIPAllocationMethod": "Dynamic",
        "dnsSettings": {
          "domainNameLabel": "[parameters('dnsNameForPublicIP')]"
        }
      }
    },
    {
      "comments": "Default Network Security Group for template",
      "type": "Microsoft.Network/networkSecurityGroups",
      "apiVersion": "2020-08-01",
      "name": "[parameters('networkSecurityGroupName')]",
      "location": "[parameters('vmLocation')]",
      "properties": {
        "securityRules": [
          {
            "name": "default-allow-3389",
            "properties": {
              "priority": 1000,
              "access": "Allow",
              "direction": "Inbound",
              "destinationPortRange": "3389",
              "protocol": "Tcp",
              "sourceAddressPrefix": "*",
              "sourcePortRange": "*",
              "destinationAddressPrefix": "*"
            }
          }
        ]
      }
    },
    {
      "apiVersion": "2020-08-01",
      "type": "Microsoft.Network/virtualNetworks",
      "name": "[variables('virtualNetworkName')]",
      "location": "[parameters('vmLocation')]",
      "dependsOn": [
        "[resourceId('Microsoft.Network/networkSecurityGroups', parameters('networkSecurityGroupName'))]"
      ],
      "properties": {
        "addressSpace": {
          "addressPrefixes": [
            "[variables('addressPrefix')]"
          ]
        },
        "subnets": [
          {
            "name": "[variables('subnetName')]",
            "properties": {
              "addressPrefix": "[variables('subnetPrefix')]",
              "networkSecurityGroup": {
                "id": "[resourceId('Microsoft.Network/networkSecurityGroups', parameters('networkSecurityGroupName'))]"
              }
            }
          }
        ]
      }
    },
    {
      "apiVersion": "2020-08-01",
      "type": "Microsoft.Network/networkInterfaces",
      "name": "[parameters('nicName')]",
      "location": "[parameters('vmLocation')]",
      "dependsOn": [
        "[parameters('publicIPAddressName')]",
        "[variables('virtualNetworkName')]"
      ],
      "properties": {
        "ipConfigurations": [
          {
            "name": "ipconfig1",
            "properties": {
              "privateIPAllocationMethod": "Dynamic",
              "publicIPAddress": {
                "id": "[resourceId('Microsoft.Network/publicIPAddresses',parameters('publicIPAddressName'))]"
              },
              "subnet": {
                "id": "[variables('subnetRef')]"
              }
            }
          }
        ]
      }
    },
    {
      "apiVersion": "2020-12-01",
      "type": "Microsoft.Compute/virtualMachines",
      "name": "[variables('vmName')]",
      "location": "[parameters('vmLocation')]",
      "dependsOn": [
        "[parameters('nicName')]"
      ],
      "identity": {
             "type": "SystemAssigned"
      } ,
      "properties": {
        "hardwareProfile": {
          "vmSize": "[parameters('vmSize')]"
        },
        "osProfile": {
          "computerName": "[variables('vmName')]",
          "adminUsername": "[parameters('adminUsername')]",
          "adminPassword": "[parameters('adminPassword')]"
        },
        "storageProfile": {
          "imageReference": {
            "publisher": "MicrosoftWindowsServer",
            "offer": "WindowsServer",
            "sku": "[parameters('osVersion')]",
            "version": "latest"
          },
          "osDisk": {
            "createOption": "FromImage"
          }
        },
        "networkProfile": {
          "networkInterfaces": [
            {
              "id": "[resourceId('Microsoft.Network/networkInterfaces',parameters('nicName'))]"
            }
          ]
        }
      }
    },
    {
      "type": "Microsoft.Automation/automationAccounts",
      "apiVersion": "2021-06-22",
      "name": "[parameters('automationAccount')]",
      "location": "[parameters('automationAccountLocation')]",
      "properties": {
        "sku": {
          "name": "Basic"
        }
      },
      "resources": [
        {
          "name": "[concat(parameters('workerGroupName'),'/',guid('AzureAutomationJobName', variables('UniqueStringBasedOnTimeStamp')))]",
          "type": "hybridRunbookWorkerGroups/hybridRunbookWorkers",
          "apiVersion": "2021-06-22",
          "dependsOn": [
            "[resourceId('Microsoft.Automation/automationAccounts', parameters('automationAccount'))]",
            "[resourceId('Microsoft.Compute/virtualMachines', variables('vmName'))]"
          ],
          "properties": {
            "vmResourceId": "[resourceId('Microsoft.Compute/virtualMachines', parameters('virtualMachineName'))]"
          }
        }
      ]
    },
    {
      "type": "Microsoft.Compute/virtualMachines/extensions",
      "name": "[concat(parameters('virtualMachineName'),'/HybridWorkerExtension')]",
      "apiVersion": "2020-12-01",
      "location": "[parameters('vmLocation')]",
      "dependsOn": [
        "[resourceId('Microsoft.Automation/automationAccounts', parameters('automationAccount'))]",
        "[resourceId('Microsoft.Compute/virtualMachines', parameters('virtualMachineName'))]"
      ],
      "properties": {
        "publisher": "Microsoft.Azure.Automation.HybridWorker",
        "type": "HybridWorkerForWindows",
        "typeHandlerVersion": "0.1",
        "autoUpgradeMinorVersion": true,
        "settings": {
          "AutomationAccountURL": "[reference(resourceId('Microsoft.Automation/automationAccounts', parameters('automationAccount'))).AutomationHybridServiceUrl]"
        }
      }
    }
  ],
  "outputs": {
    "output1": {
      "type": "string",
      "value": "[reference(resourceId('Microsoft.Automation/automationAccounts', parameters('automationAccount'))).AutomationHybridServiceUrl]"
    }
  }
}
"@