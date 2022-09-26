#description: Add new AVD hosts to a conditional access policy's MFA exclusions
#tags: Nerdio, Preview

<# Notes:
    Pre 
In Azure AD->App Registrations->API Permissions
Policy.Read.All
Policy.Read.ConditionalAccess
Policy.ReadWrite.ConditionalAccess

Device.Read.All
In Enterprise Applications->nerdio-nmw-app
Grant Admin Consent

Microsoft.Graph.Authentication
Microsoft.Graph.Identity.SignIns module
Microsoft.Graph.Identity.DirectoryManagement

#>

<# Variables:

#>

$PolicyId = '954568ef-2e2b-4d9d-a21e-272fa512186a'

$ErrorActionPreference = "Stop"

Write-Output "Connecting to Graph API"
Connect-MgGraph -Tenant $kvConnection.TenantID -ClientId $kvConnection.ApplicationID -CertificateThumbprint $kvConnection.CertificateThumbprint

Write-Output "Getting VM"
$VM = get-azvm -Name $AzureVMName -ResourceGroupName $AzureResourceGroupName

Write-Output "Getting conditional access policy"
$Policy = Get-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $PolicyId
$Exclusions = $policy.conditions.devices.devicefilter | Where-Object mode -eq exclude

if ($Exclusions) {
    $Exclusions.rule += " -or device.deviceId -eq `"$($vm.vmid)`""
}
else {
    $policy.Conditions.Devices.DeviceFilter = @{mode="exclude"; rule="device.deviceId -eq `"$($vm.vmid)`""}     
}

Write-Output "Updating policy"
Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $Policy.id -Conditions $Policy.Conditions
