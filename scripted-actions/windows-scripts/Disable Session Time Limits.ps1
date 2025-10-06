#description: Disable Session Time Limits Host Pool settings.
#execution mode: IndividualWithRestart
#tags: Nerdio
<#
Notes:
This script disables session time limits by removing next registry keys:
    HKLM:\Software\Policies\Microsoft\Windows NT\Terminal Services\MaxConnectionTime
    HKLM:\Software\Policies\Microsoft\Windows NT\Terminal Services\MaxDisconnectionTime
    HKLM:\Software\Policies\Microsoft\Windows NT\Terminal Services\MaxIdleTime
    HKLM:\Software\Policies\Microsoft\Windows NT\Terminal Services\RemoteAppLogoffTimeLimit
It also sets the fResetBroken registry key to 0.
#>

function Remove-RegistryValue {
    param (
        [string] $Name
    )

    $path = 'HKLM:\Software\Policies\Microsoft\Windows NT\Terminal Services'
    $item = Get-Item -Path $path;
    
    if ($null -ne $item.GetValue($name, $null)) 
    { 
        Remove-ItemProperty -Path $path -Name $Name 
    }
}

Remove-RegistryValue -Name "MaxConnectionTime"
Remove-RegistryValue -Name "MaxDisconnectionTime"
Remove-RegistryValue -Name "MaxIdleTime"
Remove-RegistryValue -Name "RemoteAppLogoffTimeLimit"

$path = 'HKLM:\Software\Policies\Microsoft\Windows NT\Terminal Services'
Set-ItemProperty -Path $path -Type 'DWord' -Name "fResetBroken" -Value 0