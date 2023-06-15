# description: Sets session host to drain mode for 10 minutes (configurable). Useful when creating new session host VMs to delay user connections until all initial configs are done.
#tags: Nerdio
<#
Notes:
This script deactivates (Sets to drain mode) a session host for X minutes (default is 10).
Adjust Variables below to alter to your preference:
#>

##### Variables #####
# Set the desired time in seconds for the host to be deactivated for
$SleepTime = 600

# Change this variable to $False to keep the host in drain mode
$ReactivateHost = $true

##### Script Logic #####

# Ensure correct subscription context is selected
Set-AzContext -SubscriptionId $AzureSubscriptionID

# Get hostpool resource group
$HostPoolRG = (Get-AzResource -ResourceId $HostpoolID).ResourceGroupName

# Retrieve FQDN of session host by using Tag (FQDN required by WVD Powershell command)
$HostFQDN = (Get-AzResource -ResourceGroupName $AzureResourceGroupName -Name $AzureVMName).Tags.NMW_VM_FQDN

# Use FQDN to set session host to drain mode (Unavailable)
Write-Output "INFO: Setting Session Host $HostFQDN to Drain-Mode"
Update-AzWvdSessionHost `
    -ResourceGroupName $HostPoolRG `
    -HostPoolName $HostPoolName `
    -Name $HostFQDN  `
    -AllowNewSession:$false

# Stop script if $Reactivate is false
if(!$ReactivateHost){
    Write-Output '$ReactivateHost variable set to $False in script. Keeping host in Drain mode.'
    exit
}

# Wait for X minutes
Write-Output "INFO: Waiting $SleepTime Seconds. . ."
Start-Sleep -s $SleepTime

# Switch the session host back to available
Write-Output "INFO: Setting Session Host $HostFQDN to Available"
Update-AzWvdSessionHost `
    -ResourceGroupName $HostPoolRG `
    -HostPoolName $HostPoolName `
    -Name $HostFQDN  `
    -AllowNewSession:$true
