#description: Restart the AVD Agent on host vm
#tags: Nerdio, Preview
<#
Notes:
This script will restart the AVD agent on an Azure VM. Intended for use with the Auto-heal feature
when a VM is unavailable.
#>

Write-Output "Restarting rdagent"
Get-Service | Where-Object name -eq rdagent | Restart-Service   
Write-output "AVD Agent Restarted"