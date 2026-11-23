#description: Reinstalls the RDAgent on target VM. Supports Azure and Azure Local session hosts.
#tags: Nerdio, Preview

<#
Notes:

This scripted action is intended to be used with Nerdio's Auto-heal feature. It uninstalls
the RDAgent, removes the VM from the host pool, reinstalls the RDAgent, and adds the host
back to the host pool. 

Supports both Azure VMs and Azure Local session hosts. Azure Local hosts are managed with the
Az.ConnectedMachine (Arc run commands) and Az.StackHCIVM (VM restart) PowerShell modules.
Both modules must be available in the Automation Account for the selected runtime.

This script is compatible with the ARM version of AVD (Spring 2020), and is not compatible with 
v1 (Fall 2019) Azure WVD.

#>

Write-output "Getting Host Pool Information"
$HostPool = Get-AzResource -ResourceId $HostpoolID
$HostPoolResourceGroupName = $HostPool.ResourceGroupName
$HostPoolName = $Hostpool.Name

Write-output "Detecting session host type"
$VM = Get-AzVM -Name $AzureVMName -ResourceGroupName $AzureResourceGroupName -ErrorAction SilentlyContinue
$IsAzureLocal = $false
if (!$VM) {
    $AzureLocalVM = Get-AzStackHCIVMVirtualMachine -Name $AzureVMName -ResourceGroupName $AzureResourceGroupName -ErrorAction SilentlyContinue
    if ($AzureLocalVM) {
        $IsAzureLocal = $true
        Write-output "Session host $AzureVMName is an Azure Local VM"
    }
    else {
        Throw "VM $AzureVMName was not found in resource group $AzureResourceGroupName, neither as an Azure VM nor as an Azure Local VM"
    }
}
else {
    Write-output "Session host $AzureVMName is an Azure VM"
}

function Invoke-SessionHostScript {
    param(
        [Parameter(Mandatory = $true)][string]$Script,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ($IsAzureLocal) {
        $RunCommandName = 'nmw-' + ($Label.ToLower() -replace '[^a-z0-9]+', '-')

        write-output "${Label}: executing Arc run command on $AzureVMName"
        try {
            $RunCommand = New-AzConnectedMachineRunCommand -ResourceGroupName $AzureResourceGroupName -MachineName $AzureVMName -RunCommandName $RunCommandName -Location $AzureRegionName -SourceScript $Script -TimeoutInSecond 3600

            Write-output "Output from RunCommand:"
            $RunCommand.InstanceViewOutput
            if ($RunCommand.InstanceViewExecutionState -ne 'Succeeded') {
                Throw "${Label}: run command did not complete successfully (state: $($RunCommand.InstanceViewExecutionState)). $($RunCommand.InstanceViewExecutionMessage) $($RunCommand.InstanceViewError)"
            }
            if ($RunCommand.InstanceViewError) {
                Throw "${Label}: error output from run command. $($RunCommand.InstanceViewError)"
            }
        }
        finally {
            Remove-AzConnectedMachineRunCommand -ResourceGroupName $AzureResourceGroupName -MachineName $AzureVMName -RunCommandName $RunCommandName -ErrorAction SilentlyContinue | Out-Null
        }
    }
    else {
        $ScriptPath = ".\$Label-$AzureVMName.ps1"
        $Script | Out-File $ScriptPath

        # Execute local script on remote VM
        write-output "${Label}: executing run command on $AzureVMName"
        $RunCommand = Invoke-AzVMRunCommand -ResourceGroupName $AzureResourceGroupName -VMName "$AzureVMName" -CommandId 'RunPowerShellScript' -ScriptPath $ScriptPath

        #Check for errors
        $errors = $RunCommand.Value | ? Code -eq 'ComponentStatus/StdErr/succeeded'
        if ($errors.message) {
            Throw "${Label}: error output from run command. $($errors.message)"
        }
        Write-output "Output from RunCommand:"
        $RunCommand.Value | ? Code -eq 'ComponentStatus/StdOut/succeeded' | select message -ExpandProperty message
    }
}

function Restart-SessionHostVm {
    if ($IsAzureLocal) {
        write-output "Restarting Azure Local VM $AzureVMName"
        Restart-AzStackHCIVMVirtualMachine -Name $AzureVMName -ResourceGroupName $AzureResourceGroupName | Out-Null
        write-output "Azure Local VM restart completed"
    }
    else {
        Restart-AzVM -ResourceGroupName $AzureResourceGroupName -Name $AzureVMName
    }
}

function Wait-ArcAgentConnected {
    write-output "Waiting for Azure Arc agent on $AzureVMName to reconnect"
    Start-Sleep -Seconds 60
    $Deadline = (Get-Date).AddMinutes(20)
    do {
        $AgentStatus = (Get-AzConnectedMachine -Name $AzureVMName -ResourceGroupName $AzureResourceGroupName -ErrorAction SilentlyContinue).Status
        if ($AgentStatus -ne 'Connected') { Start-Sleep -Seconds 15 }
    } while ($AgentStatus -ne 'Connected' -and (Get-Date) -lt $Deadline)

    if ($AgentStatus -ne 'Connected') {
        Throw "Azure Arc agent on $AzureVMName did not reconnect after restart. Last status: $AgentStatus"
    }
    write-output "Azure Arc agent is connected"
}

$Script = @"
`$tempFolder = [environment]::GetEnvironmentVariable('TEMP', 'Machine')
`$logsFolderName = "NMWLogs"
`$logsPath = "`$tempFolder\`$logsFolderName"
if (-not (Test-Path -Path `$logsPath)) {
    New-Item -Path `$tempFolder -Name `$logsFolderName -ItemType Directory -Force | Out-Null
}

`$wvdAppsLogsFolderName = "WVDApps"
`$wvdAppsLogsPath = "`$logsPath\`$wvdAppsLogsFolderName"
if (-not (Test-Path -Path `$wvdAppsLogsPath)) {
    New-Item -Path `$logsPath -Name `$wvdAppsLogsFolderName -ItemType Directory -Force | Out-Null
}

`$AgentGuids = get-wmiobject Win32_Product | where-Object Name -eq 'Remote Desktop Services Infrastructure Agent' | select identifyingnumber -ExpandProperty identifyingnumber
Write-Output "Uninstalling any previous versions of RD Agent on VM"
Foreach (`$guid in `$AgentGuids) {
    `$avd_uninstall_status = Start-Process -FilePath "msiexec.exe" -ArgumentList "/x `$guid", "/quiet", "/qn", "/norestart", "/passive", "/l* `$wvdAppsLogsPath\RDAgentUninstall.log" -Wait -Passthru
    `$sts = `$avd_uninstall_status.ExitCode
    Write-Output "Uninstalling AVD Agetnt on VM Complete. Exit code=`$sts"
    
}
"@

write-output "Execute uninstall script on remote VM"
Invoke-SessionHostScript -Script $Script -Label 'Uninstall-AVDAgent'

write-output "Restarting VM after uninstall"
Restart-SessionHostVm

$SessionHost = Get-AzWvdSessionHost -HostPoolName $hostpoolname -ResourceGroupName $HostPoolResourceGroupName | ? name -match $azureVMName
Remove-AzWvdSessionHost -ResourceGroupName $HostPoolResourceGroupName -HostPoolName $HostPoolName -Name ($SessionHost.name -split '/')[1]
write-output "Removed session host from host pool"

$RegistrationKey = Get-AzWvdRegistrationInfo -ResourceGroupName $HostPoolResourceGroupName -HostPoolName $HostPoolName
if (-not $RegistrationKey.Token) {
    # Generate New Registration Token
    Write-Output "Generate New Registration Token"
    $RegistrationKey = New-AzWvdRegistrationInfo -ResourceGroupName $HostPoolResourceGroupName -HostPoolName $HostPoolName -ExpirationTime $((get-date).ToUniversalTime().AddDays(1).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'))
}

$RegistrationToken = $RegistrationKey.token


$Script = @"
`$tempFolder = [environment]::GetEnvironmentVariable('TEMP', 'Machine')
`$logsFolderName = "NMWLogs"
`$logsPath = "`$tempFolder\`$logsFolderName"
if (-not (Test-Path -Path `$logsPath)) {
    New-Item -Path `$tempFolder -Name `$logsFolderName -ItemType Directory -Force | Out-Null
}

`$wvdAppsLogsFolderName = "WVDApps"
`$wvdAppsLogsPath = "`$logsPath\`$wvdAppsLogsFolderName"
if (-not (Test-Path -Path `$wvdAppsLogsPath)) {
    New-Item -Path `$logsPath -Name `$wvdAppsLogsFolderName -ItemType Directory -Force | Out-Null
}

`$AgentInstaller = (Get-ChildItem 'C:\Program Files\Microsoft RDInfra\' | ? name -Match Microsoft.RDInfra.RDAgent.Installer | sort lastwritetime -Descending | select -First 1).fullname
`$InstallerPath = '"' + `$AgentInstaller + '"'

Write-Output "Installing RD Infra Agent on VM `$InstallerPath"

`$agent_deploy_status = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `$installerPath", "/quiet", "/qn", "/norestart", "/passive", "REGISTRATIONTOKEN=$RegistrationToken", "/l* `$wvdAppsLogsPath\RDInfraAgentInstall.log" -Wait -Passthru
`$sts = `$agent_deploy_status.ExitCode
Write-Output "Installing RD Infra Agent on VM Complete. Exit code=`$sts"
`$Log = get-content `$wvdAppsLogsPath\RDInfraAgentInstall.log 
Write-output `$log
"@

if ($IsAzureLocal) {
    Wait-ArcAgentConnected
}

write-output "Execute reinstall script on remote VM"
Invoke-SessionHostScript -Script $Script -Label 'Reinstall-AVDAgent'

write-output "Restarting VM after reinstall"
Restart-SessionHostVm

# re-assigning user
if ($SessionHost.assigneduser) {
    Update-AzWvdSessionHost -HostPoolName $hostpoolname -Name ($SessionHost.name -split '/')[1] -AssignedUser $SessionHost.AssignedUser -ResourceGroupName $HostPoolResourceGroupName
}