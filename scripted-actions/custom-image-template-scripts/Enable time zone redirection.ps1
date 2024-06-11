<#
  Author: Akash Chawla
  Source: https://github.com/Azure/RDS-Templates/tree/master/CustomImageTemplateScripts/CustomImageTemplateScripts_2024-03-27
#>

#description: Allow the client to redirect its time zone to session host
#execution mode: Individual
#tags: Microsoft, Custom Image Template Scripts

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
Write-Host "*** AVD AIB CUSTOMIZER PHASE: Timezone redirection ***"

$registryPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
$registryKey = "fEnableTimeZoneRedirection"
$registryValue = "1"

IF(!(Test-Path $registryPath)) {
    New-Item -Path $registryPath -Force | Out-Null
}

try {
    New-ItemProperty -Path $registryPath -Name $registryKey -Value $registryValue -PropertyType DWORD -Force | Out-Null
}
catch {
    Write-Host "*** AVD AIB CUSTOMIZER PHASE ***  Timezone redirection - Cannot add the registry key *** : [$($_.Exception.Message)]"
    Write-Host "Message: [$($_.Exception.Message)"]
}

$stopwatch.Stop()
$elapsedTime = $stopwatch.Elapsed
Write-Host "*** AVD AIB CUSTOMIZER PHASE: Timezone redirection -  Exit Code: $LASTEXITCODE ***"
Write-Host "*** AVD AIB CUSTOMIZER PHASE: Timezone redirection - Time taken: $elapsedTime ***"

#############
#    END    #
#############