$tempFolder = [environment]::GetEnvironmentVariable('TEMP', 'Machine')
$logsFolderName = "NMWLogs"
$logsPath = "$tempFolder\$logsFolderName"
if (-not (Test-Path -Path $logsPath)) {
    New-Item -Path $tempFolder -Name $logsFolderName -ItemType Directory -Force | Out-Null
}

$wvdAppsLogsFolderName = "WVDApps"
$wvdAppsLogsPath = "$logsPath\$wvdAppsLogsFolderName"
if (-not (Test-Path -Path $wvdAppsLogsPath)) {
    New-Item -Path $logsPath -Name $wvdAppsLogsFolderName -ItemType Directory -Force | Out-Null
}

Write-Output "Uninstalling any previous versions of RD SxS Network Stack on VM"
$sxs_uninstall_status = Start-Process -FilePath "msiexec.exe" -ArgumentList "/x {41B5388E-5594-498C-9864-7F5C1300250E}", "/quiet", "/qn", "/norestart", "/passive", "/l* $wvdAppsLogsPath\SxSNetworkStackUninstall.log" -Wait -Passthru
$sts = $sxs_uninstall_status.ExitCode
Write-Output "Uninstalling RD SxS Network Stack on VM Complete. Exit code=$sts`n"


$SxSInstaller = Get-ChildItem -path 'C:\Program Files\Microsoft RDInfra' | Where-Object Name -Match '^SxsStack-' | sort LastWriteTime -Descending | select -First 1
$sxs_install_status = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i $($SxSInstaller.FullName)" "/quiet", "/qn", "/norestart", "/passive", "/l* $wvdAppsLogsPath\SxSNetworkStackUninstall.log" -Wait -Passthru
$sts = $sxs_install_status.ExitCode
$sts = $sxs_uninstall_status.ExitCode
Write-Output "Installing RD SxS Network Stack on VM Complete. Exit code=$sts`n"