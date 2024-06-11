<#
  Author: Akash Chawla
  Source: https://github.com/Azure/RDS-Templates/tree/master/CustomImageTemplateScripts/CustomImageTemplateScripts_2024-03-27
#>

#description: Configure timeout thresholds for sessions
#execution mode: Individual
#tags: Microsoft, Custom Image Template Scripts
<#variables:
{
  "MaxDisconnectionTime": {
    "Description": "Set time limit for disconnected sessions",
    "DisplayName": "Time limit for disconnected sessions",
    "IsRequired": true,
    "OptionsSet": [
      {"Label": "Never", "Value": "0"},
      {"Label": "1 minute", "Value": "1"},
      {"Label": "5 minutes", "Value": "2"},
      {"Label": "10 minutes", "Value": "3"},
      {"Label": "15 minutes", "Value": "4"},
      {"Label": "30 minutes", "Value": "5"},
      {"Label": "1 hour", "Value": "6"},
      {"Label": "2 hours", "Value": "7"},
      {"Label": "3 hours", "Value": "8"},
      {"Label": "6 hours", "Value": "9"},
      {"Label": "8 hours", "Value": "10"},
      {"Label": "12 hours", "Value": "11"},
      {"Label": "16 hours", "Value": "12"},
      {"Label": "18 hours", "Value": "13"},
      {"Label": "1 day", "Value": "14"},
      {"Label": "2 days", "Value": "15"},
      {"Label": "3 days", "Value": "16"},
      {"Label": "4 days", "Value": "17"},
      {"Label": "5 days", "Value": "18"}
    ]
  },
  "MaxIdleTime": {
    "Description": "Set time limit for active but idle Remote Desktop Services sessions",
    "DisplayName": "Time limit for active but idle sessions",
    "IsRequired": true,
    "OptionsSet": [
      {"Label": "Never", "Value": "0"},
      {"Label": "1 minute", "Value": "1"},
      {"Label": "5 minutes", "Value": "2"},
      {"Label": "10 minutes", "Value": "3"},
      {"Label": "15 minutes", "Value": "4"},
      {"Label": "30 minutes", "Value": "5"},
      {"Label": "1 hour", "Value": "6"},
      {"Label": "2 hours", "Value": "7"},
      {"Label": "3 hours", "Value": "8"},
      {"Label": "6 hours", "Value": "9"},
      {"Label": "8 hours", "Value": "10"},
      {"Label": "12 hours", "Value": "11"},
      {"Label": "16 hours", "Value": "12"},
      {"Label": "18 hours", "Value": "13"},
      {"Label": "1 day", "Value": "14"},
      {"Label": "2 days", "Value": "15"},
      {"Label": "3 days", "Value": "16"},
      {"Label": "4 days", "Value": "17"},
      {"Label": "5 days", "Value": "18"}
    ]
  },
  "MaxConnectionTime": {
    "Description": "Set time limit for active Remote Desktop Services sessions",
    "DisplayName": "Time limit for active sessions",
    "IsRequired": true,
    "OptionsSet": [
      {"Label": "Never", "Value": "0"},
      {"Label": "1 minute", "Value": "1"},
      {"Label": "5 minutes", "Value": "2"},
      {"Label": "10 minutes", "Value": "3"},
      {"Label": "15 minutes", "Value": "4"},
      {"Label": "30 minutes", "Value": "5"},
      {"Label": "1 hour", "Value": "6"},
      {"Label": "2 hours", "Value": "7"},
      {"Label": "3 hours", "Value": "8"},
      {"Label": "6 hours", "Value": "9"},
      {"Label": "8 hours", "Value": "10"},
      {"Label": "12 hours", "Value": "11"},
      {"Label": "16 hours", "Value": "12"},
      {"Label": "18 hours", "Value": "13"},
      {"Label": "1 day", "Value": "14"},
      {"Label": "2 days", "Value": "15"},
      {"Label": "3 days", "Value": "16"},
      {"Label": "4 days", "Value": "17"},
      {"Label": "5 days", "Value": "18"}
    ]
  },
  "RemoteAppLogoffTimeLimit": {
    "Description": "Set time limit for logoff of RemoteApp sessions",
    "DisplayName": "Time limit to logoff sessions",
    "IsRequired": true,
    "OptionsSet": [
      {"Label": "Never", "Value": "0"},
      {"Label": "1 minute", "Value": "1"},
      {"Label": "5 minutes", "Value": "2"},
      {"Label": "10 minutes", "Value": "3"},
      {"Label": "15 minutes", "Value": "4"},
      {"Label": "30 minutes", "Value": "5"},
      {"Label": "1 hour", "Value": "6"},
      {"Label": "2 hours", "Value": "7"},
      {"Label": "3 hours", "Value": "8"},
      {"Label": "6 hours", "Value": "9"},
      {"Label": "8 hours", "Value": "10"},
      {"Label": "12 hours", "Value": "11"},
      {"Label": "16 hours", "Value": "12"},
      {"Label": "18 hours", "Value": "13"},
      {"Label": "1 day", "Value": "14"},
      {"Label": "2 days", "Value": "15"},
      {"Label": "3 days", "Value": "16"},
      {"Label": "4 days", "Value": "17"},
      {"Label": "5 days", "Value": "18"}
    ]
  },
  "fResetBroken": {
    "DisplayName": "End session when time limits are reached"
  }
}
#>

[CmdletBinding()]
  Param (
        [Parameter(Mandatory=$false)]
        [string] $MaxDisconnectionTime,

        [Parameter(Mandatory=$false)]
        [string] $MaxIdleTime,

        [Parameter(Mandatory=$false)]
        [string] $MaxConnectionTime,

        [Parameter(Mandatory=$false)]
        [string] $RemoteAppLogoffTimeLimit,

        [Parameter(Mandatory=$false)]
        [switch] $fResetBroken
 )

 
 function ConvertToMilliSecond($timeInMinutes) {
    return (60 * 1000 * $timeInMinutes)
 }

 function Set-RegKey($registryPath, $registryKey, $registryValue) {
    try {
         Write-Host "*** AVD AIB CUSTOMIZER PHASE *** Configure session timeouts - Setting  $registryKey with value $registryValue ***"
         New-ItemProperty -Path $registryPath -Name $registryKey -Value $registryValue -PropertyType DWORD -Force -ErrorAction Stop
    }
    catch {
         Write-Host "*** AVD AIB CUSTOMIZER PHASE *** Configure session timeouts - Cannot add the registry key  $registryKey *** : [$($_.Exception.Message)]"
    }
 }

 $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

 $templateFilePathFolder = "C:\AVDImage"
 $registryPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
 Write-host "Starting AVD AIB Customization: Configure session timeouts"

 IF(!(Test-Path $registryPath)) {
   New-Item -Path $registryPath -Force | Out-Null
 }

foreach($parameter in $PSBoundParameters.GetEnumerator()) {

    $registryKey = $parameter.Key

    if($registryKey.Equals("fResetBroken")) {
        $registryValue = "1"
        Set-RegKey -registryPath $registryPath -registryKey $registryKey -registryValue $registryValue
        break
    } 

    $registryValue = ConvertToMilliSecond -time $parameter.Value
    Set-RegKey -registryPath $registryPath -registryKey $registryKey -registryValue $registryValue
}

if ((Test-Path -Path $templateFilePathFolder -ErrorAction SilentlyContinue)) {
    Remove-Item -Path $templateFilePathFolder -Force -Recurse -ErrorAction Continue
}

$stopwatch.Stop()
$elapsedTime = $stopwatch.Elapsed
Write-Host "*** AVD AIB CUSTOMIZER PHASE: Configure session timeouts - Exit Code: $LASTEXITCODE ***"
Write-host "Ending AVD AIB Customization: Configure session timeouts - Time taken: $elapsedTime "

