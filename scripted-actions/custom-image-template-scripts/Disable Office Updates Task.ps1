<#
  Author      : Cristian Schmitt Nieto
  Source      : https://learn.microsoft.com/en-us/microsoft-365/troubleshoot/updates/office-feature-updates-task-faq
#>

#description: Toggle the built-in "Office Feature Updates" scheduled task to avoid performance issues on multi-session hosts.
#execution mode: Individual
#tags: CSN, Microsoft, Golden Image, Scheduled Task, OfficeUpdates

<#variables:
{
  "Action": {
    "Description": "Enable or disable the Office Feature Updates scheduled task.",
    "DisplayName": "Office Update Task Action",
    "IsRequired": true,
    "OptionsSet": [
      { "Label": "Enable",  "Value": "Enable"  },
      { "Label": "Disable", "Value": "Disable" }
    ]
  }
}
#>

param (
  [Parameter(Mandatory)]
  [ValidateSet("Enable","Disable")]
  [string]$Action
)

$TaskName = 'Office Feature Updates'
$TaskPath = '\Microsoft\Office\'

Write-Host "Starting Office Update Task configuration: $Action..."

# Attempt to retrieve the task
$task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue

if (-not $task) {
    Write-Error "Scheduled task '$TaskPath$TaskName' not found."
    exit 1
}

switch ($Action) {
  'Enable' {
    Write-Host "Enabling scheduled task '$TaskPath$TaskName'..."
    Enable-ScheduledTask -InputObject $task
    Write-Host "Task enabled."
  }

  'Disable' {
    Write-Host "Disabling scheduled task '$TaskPath$TaskName'..."
    Disable-ScheduledTask -InputObject $task
    Write-Host "Task disabled."
  }
}

Write-Host "Completed Office Update Task configuration: $Action"
