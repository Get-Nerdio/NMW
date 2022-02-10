#description: Unassigns a user from a personal desktop
#tags: Nerdio, Preview

<#
Notes:

This runbook only works on ARM (Spring 2020) host pools, not pre-ARM (Fall 2019)

This runbook relies on the Az.DesktopVirtualization powershell module. 
This module must be installed into the Nerdio manager scripted actions automation account. 
See here for information on installing modules:

https://docs.microsoft.com/en-us/azure/automation/shared-resources/modules

Start this runbook by going to the host pool, clicking "Manage Hosts" and selecting "Run script"
from the drop-down menu for the host.

#>

<# Variables:
#>

import-module Az.DesktopVirtualization 

if (get-module Az.DesktopVirtualization) {
   write-output "Az.DesktopVirtualization module present"
}
else {
   Throw "Az.DesktopVirtualization module not present. Install the module in the nerdio runbook Automation Account."
   exit
}

if ($AzureResourceGroupName -eq '')
{
  Write-Error "Unable to resolve ResourceGroupName. Host Pool may not be ARM (Spring 2020) release."
  exit
}


$VMResourceGroupName = $AzureResourceGroupName
$HostPoolResourceGroupName = $HostPoolId.Split('/', [System.StringSplitOptions]::RemoveEmptyEntries)[3]

write-output "getting vm"
$VM = Get-AzVM -ResourceGroupName $VMResourceGroupName -Name $AzureVMName

$VMStatus = Get-AzVM -ResourceGroupName $VMResourceGroupName -Name $AzureVMName -Status
if (!($VMStatus.Statuses.code -match 'running')) {
    Write-Output "Starting VM $AzureVMName"
    $VM | Start-AzVM 
}

try {
    # Get registration token
    $RegistrationKey = Get-AzWvdRegistrationInfo -ResourceGroupName $HostPoolResourceGroupName -HostPoolName $HostPoolName
    if (-not $RegistrationKey.Token) {
        # Generate New Registration Token
        Write-Output "Generate New Registration Token"
        $RegistrationKey = New-AzWvdRegistrationInfo -ResourceGroupName $HostPoolResourceGroupName -HostPoolName $HostPoolName -ExpirationTime $((get-date).ToUniversalTime().AddDays(1).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'))
    }

    # Making AzureVMName Fully Qualified
    $tag = $vm.tags.Keys -match 'VM_FQDN'
    $AzureVMNameFQDN = $vm.Tags[$tag][0]

    $SessionHost = Get-AzWvdSessionHost -HostPoolName $HostPoolName -Name $AzureVMNameFQDN -ResourceGroupName $HostPoolResourceGroupName
    $DesktopUser = $SessionHost.AssignedUser

    if ([string]::IsNullOrEmpty($DesktopUser)) {
        Write-Error "No user is assigned to this session host"
        Throw "No user is assigned to session host"
    }

    # Removing Host from the HostPool"
    write-output "Removing Host $AzureVMNameFQDN from the HostPool $HostPoolName"

    Remove-AzWvdSessionHost -ResourceGroupName $HostPoolResourceGroupName -HostPoolName $HostPoolName -Name $AzureVMNameFQDN -Force 
    
    # Remove the NMW_USERNAME tag
    Write-Output "Removing the NMW_USERNAME tag"
    $key = $vm.tags.keys | ? {$_ -match '^N\w\w_USERNAME'}
    if ($key)  {
        $Deletetag = @{$key= $vm.tags.$($key)} 
        Update-AzTag -ResourceID $vm.ID -tag $deletetag -Operation Delete
    }
    else {
        Write-Output "Username tag does not exist"
    }
    # Execute local script on remote VM
    $Script = @"
Set-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\RDInfraAgent\ -Name IsRegistered -Value 0
Set-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\RDInfraAgent\ -Name RegistrationToken -Value $($RegistrationKey.Token)
Restart-Service RDAgent
Start-service RDAgentBootLoader
"@
$Script | Out-File ".\RemoveAssignment-$($vm.Name).ps1"

    # Execute local script on remote VM
    write-output "Execute local script on remote VM"
    Invoke-AzVMRunCommand -ResourceGroupName $VMResourceGroupName -VMName "$AzureVMName" -CommandId 'RunPowerShellScript' -ScriptPath ".\RemoveAssignment-$($vm.Name).ps1"
}

Catch {
    Throw $_
}

Finally {
    if (!($VMStatus.Statuses.code -match 'running'))  {
        write-output "stopping VM"
        $VM | Stop-AzVM -Force
    }
    else {
        $VM | Restart-AzVM 
    }
}
