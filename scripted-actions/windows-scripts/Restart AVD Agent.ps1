Write-Output "Restarting rdagent"
Get-Service | Where-Object name -eq rdagent | Restart-Service   
Write-output "AVD Agent Restarted"