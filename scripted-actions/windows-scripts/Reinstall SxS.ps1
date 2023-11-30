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

$SxSGuids = get-wmiobject Win32_Product | where-Object Name -eq 'Remote Desktop Services SxS Network Stack' | select identifyingnumber -ExpandProperty identifyingnumber

Write-Output "Uninstalling any previous versions of RD SxS Network Stack on VM"
Foreach ($guid in $SxSGuids) {
    $sxs_uninstall_status = Start-Process -FilePath "msiexec.exe" -ArgumentList "/x $guid", "/quiet", "/qn", "/norestart", "/passive", "/l* $wvdAppsLogsPath\SxSNetworkStackUninstall.log" -Wait -Passthru
    $sts = $sxs_uninstall_status.ExitCode
    Write-Output "Uninstalling RD SxS Network Stack on VM Complete. Exit code=$sts`n"
    
}


$SxSInstaller = Get-ChildItem -path 'C:\Program Files\Microsoft RDInfra' | Where-Object Name -Match '^SxsStack-' | sort LastWriteTime -Descending | select -First 1
Write-output "Got SxS installer file $($SxSInstaller.FullName)"
$sxs_install_status = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i $($SxSInstaller.FullName)", "/quiet", "/qn", "/norestart", "/passive", "/l* $wvdAppsLogsPath\SxSNetworkStackInstall.log" -Wait -Passthru
$sts = $sxs_install_status.ExitCode
Write-Output "Installing RD SxS Network Stack on VM Complete. Exit code=$sts`n"