#description: (PREVIEW) Creates a NAT gateway on a subnet
#tags: Nerdio, Preview

<#
Notes:

This script creates a public IP address and NAT Gateway, and associates it with the given subnet. 

For more information on NAT gateways in Azure, see:
https://learn.microsoft.com/en-us/azure/virtual-network/nat-gateway/nat-overview

#>

<# Variables:
{
  "VNetRG": {
    "Description": "The VNet's resource group.",
    "IsRequired": true
  },
  "VNetName": {
    "Description": "VNet in which to create the NAT Gateway.",
    "IsRequired": true
  },
  "SubnetName": {
    "Description": "Subnet with which to associate the NAT Gateway.",
    "IsRequired": true
  }
}
#>

# Adjust Variables below to alter to your preference:

$ErrorActionPreference = 'Stop'


##### Required Variables #####

$GatewayName = $VNetName + '-' + $SubnetName + '-NATGateway'
$PublicIpName = $GatewayName + '-PIP'

Try {
    write-output "Getting VNet"
    $vnet = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $VNetRG
    Write-Output "Creating Public IP"
    $pip = New-AzPublicIpAddress -Name $PublicIpName -ResourceGroupName $VNetRG -Location $vnet.location -Sku "Standard" -IdleTimeoutInMinutes 4 -AllocationMethod "static"
    Write-Output "Creating NAT Gateway"
    $natgateway = New-AzNatGateway -Name $GatewayName -ResourceGroupName $VNetRG -IdleTimeoutInMinutes 4 -Sku "Standard" -Location $vnet.Location -PublicIpAddress $pip 

    $subnet = Get-AzVirtualNetworkSubnetConfig -Name $SubnetName -VirtualNetwork $vnet
    $subnet.NatGateway = $natgateway
    Write-Output "Updating VNet"
    $vnet | Set-AzVirtualNetwork 
}
Catch {
    if ($natgateway) {
        
        if ($subnet.NatGateway -eq $natgateway) {
            Write-Output "Removing nat gateway from subnet"
            $subnet.NatGateway = $null
            $vnet | Set-AzVirtualNetwork 
        }
        Write-Output "Removing NAT gateway"
        $natgateway | Remove-AzNatGateway -Force 
    }
    if ($pip) {
        Write-Output "Removing PIP"
        $pip | Remove-AzPublicIpAddress -Force
    }
    Throw $_ 
}
