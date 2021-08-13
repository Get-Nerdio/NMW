#description: Unassigns a user from a personal desktop
#tags: Nerdio, Preview
<#
Notes:

#>

<# Variables:
{
  "VariableName": {
    "Description": "Description",
    "IsRequired": false,
    "DefaultValue": ""
  }
}


#>

# Generate New Registration Token
$RegistrationKey = New-AzWvdRegistrationInfo -ResourceGroupName $AzureCoreResourceGroupName -HostPoolName $HostPoolName -ExpirationTime $((get-date).ToUniversalTime().AddDays(1).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'))
 
# Making AzureVMName Fully Qualified
$AzureVMNameFQDN = $AzureVMName + 'NEEDS LOGIC TO AUTOMATICALLY DETERMINE THIS’
 
# Removing Host from the HostPool"
Remove-AzWvdSessionHost -ResourceGroupName $AzureCoreResourceGroupName -HostPoolName $HostPoolName -Name $AzureVMNameFQDN -Force
 
# Execute local script on remote VM
$Script = @"
Set-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\RDInfraAgent\ -Name IsRegistered -Value 0
Set-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\RDInfraAgent\ -Name RegistrationToken -Value $($RegistrationKey.Token)
Restart-Service RDAgent
Start-service RDAgentBootLoader
"@
$Script | Out-File ".\RemoveAssignment.ps1"
 
# Execute local script on remote VM
Invoke-AzVMRunCommand -ResourceGroupName $AzureResourceGroupName -VMName $AzureVMName -CommandId 'RunPowerShellScript' -ScriptPath '.\RemoveAssignment.ps1'