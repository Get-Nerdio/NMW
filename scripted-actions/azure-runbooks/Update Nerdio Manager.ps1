#description: Update NME to the latest release.
#tags: Nerdio, Preview

<# Notes:

This Scripted Action will update the NME (Nerdio Manager) application to the latest version. 
You can schedule this SA to keep Nerdio up to date automatically. During the update process
The NME interface may be momentarily unavailable, but AVD hosts will be unaffected.

This SA requires the Az.Accounts and Az.Websites modules to be installed in the Azure Automation
Account that runs the Nerdio scripted actions

#>

<# Variables:
{
  "InstallPreviewVersions": {
    "Description": "Set to True to install preview versions of Nerdio Manager",
    "IsRequired": true,
    "DefaultValue": "False"
  }
}
#>

$ErrorActionPreference = 'Stop'
$ApiUri = 'https://nwp-web-app.azurewebsites.net'
$InstallPreviewVersions = [System.Convert]::ToBoolean($InstallPreviewVersions)

$Context = Get-AzContext

$webAppName = $keyVaultName -replace '\-kv',''
$azureEnv = $Context.Environment.Name
$KeyVault = Get-AzKeyVault -VaultName $keyVaultName
$resourceGroupName = $KeyVault.ResourceGroupName
$subscriptionId = ($Context.Subscription).id


Import-Module Az.Websites
Import-Module Az.Accounts

$InstallId = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name InstallParams--Id -AsPlainText

$Headers = @{'Install-Id' = $InstallId}

$PublishedVersions = Invoke-RestMethod $ApiUri/api/package -Method Get -Headers $Headers

# Check for a previous run of this script. If one exists, it means this script was re-started after the last run  
# we show the previous output and exit

Function Check-LastRunResults {
Param()
    $KeyVault = get-azkeyvault -vaultname $KeyVaultName
    $MinutesAgo = 10
    $NmeString = ($keyvaultname -split '-')[3]
    $app = Get-AzWebApp -ResourceGroupName $keyvault.ResourceGroupName -Name nmw-app-$NmeString
    if ($app.LastModifiedTimeUtc -gt (get-date).AddMinutes(-$MinutesAgo)) {
        Write-Output "Web job has been restarted recently. Checking for previous script run"
        $AutomationAccount = Get-AzAutomationAccount -ResourceGroupName $keyvault.ResourceGroupName | where-object automationaccountname -Match 'runbooks|scripted\-actions'
        $ThisJob = Get-AzAutomationJob -id $PSPrivateMetadata['JobId'].Guid -resourcegroupname $keyvault.resourcegroupname -AutomationAccountName $automationAccount.automationAccountname 
        Invoke-WebRequest -UseBasicParsing -Uri $ThisJob.JobParameters.scriptUri -OutFile .\ThisScript.ps1
        $ThisScriptHash = Get-FileHash .\ThisScript.ps1

        $jobs = Get-AzAutomationJob -resourcegroupname $keyvault.resourcegroupname -AutomationAccountName $automationAccount.automationAccountname | ? status -eq completed | ? {$_.EndTime.datetime -gt (get-date).AddMinutes(-$MinutesAgo)}
        foreach ($job in $jobs){
            $details = Get-AzAutomationJob -id $job.JobId -resourcegroupname $keyvault.resourcegroupname -AutomationAccountName $automationAccount.automationAccountname 
            Invoke-WebRequest -UseBasicParsing -Uri $details.JobParameters.scriptUri -OutFile .\JobScript.ps1 
            $JobHash = Get-FileHash .\JobScript.ps1 
            if ($JobHash.hash -eq $ThisScriptHash.hash){
                Write-Output "Output of previous script run:"
                Get-AzAutomationJobOutput -Id $details.JobId -resourcegroupname $keyvault.resourcegroupname -AutomationAccountName $automationAccount.automationAccountname | select summary -ExpandProperty summary
                Write-Output "App Service restarted after successfully running this script."
                Exit
            }
        }
    }
}

Check-LastRunResults

function Get-CurrentAppVersion {
param(
    $SubscriptionId,
    $webAppName,
    $ResourceGroupName
)
function Get-AzCachedAccessToken()
{
    $ErrorActionPreference = 'Stop'
  
    if(-not (Get-Module Az.Accounts)) {
        Import-Module Az.Accounts
    }
    $azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
    if(-not $azProfile.Accounts.Count) {
        Write-Error "Ensure you have logged in before calling this function."    
    }
  
    $currentAzureContext = Get-AzContext
    $profileClient = New-Object Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient($azProfile)
    Write-Debug ("Getting access token for tenant" + $currentAzureContext.Tenant.TenantId)
    $token = $profileClient.AcquireAccessToken($currentAzureContext.Tenant.TenantId)
    return $token.AccessToken
}
function Get-BearerToken()
{
    $ErrorActionPreference = 'Stop'
    $token = Get-AzCachedAccessToken
    return ("Bearer " + $token)
}
function Get-ResourceManagerUrl {
    $ctx = Get-AzContext
    return $ctx.Environment.ResourceManagerUrl
}
function Get-ScmUriSuffix {
    $ctx = Get-AzContext
    if ($ctx.Environment.Name -eq "AzureUSGovernment") {
        return ".scm.azurewebsites.us"
    } else {
        return ".scm.azurewebsites.net"
    }
}
function Get-AuthInfo {
    Param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    $bearerToken = Get-BearerToken
    $baseUri = Get-ResourceManagerUrl
    $apiUri = $baseUri + "subscriptions/"+ $SubscriptionId +"/resourceGroups/"+$ResourceGroupName+"/providers/Microsoft.Web/sites/"+$Name+"/publishxml?api-version=2016-08-01"
    $result = Invoke-RestMethod -Uri $apiUri -Headers @{Authorization=$bearerToken} -Method POST -ContentType "application/json" -Body @{format = "WebDeploy"}
    [xml]$publishSettings = $result.InnerXml
    $website = $publishSettings.SelectSingleNode("//publishData/publishProfile[@publishMethod='MSDeploy']")
    $username = $webSite.userName
    $password = $webSite.userPWD
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $username,$password)))
    return $base64AuthInfo
}
function Get-ApiUri  {
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Method
    )
    $scmSuffix = Get-ScmUriSuffix
    $apiUri ="https://" + $Name + $scmSuffix + "/api/" + $Method
    return $apiUri
}
$outFilePath = "$env:TEMP\Denver.DBL.dll"
$authInfo = Get-AuthInfo -SubscriptionId $subscriptionid -ResourceGroupName $resourceGroupName -Name $webAppName
$uri = Get-ApiUri -Name $webAppName -Method 'vfs/site/wwwroot/Denver.DBL.dll'
$response = Invoke-RestMethod -Uri $uri -Headers @{Authorization=("Basic {0}" -f $authInfo)} -Method Get -OutFile $outFilePath
[System.Diagnostics.FileVersionInfo]::GetVersionInfo($outFilePath).FileVersion
}

$CurrentVersion = Get-CurrentAppVersion -SubscriptionId $subscriptionId -webAppName $webAppName -ResourceGroupName $resourceGroupName

Write-Output "Current version is $CurrentVersion."

if ($InstallPreviewVersions){
    $NewVersion = $PublishedVersions | Where-Object {[System.Version]$_.version -gt [System.Version]$CurrentVersion} | Sort-Object -Property {[System.Version]$_.version} -Descending | Select-Object -First 1
}
else {
    $NewVersion = $PublishedVersions | Where-Object {[System.Version]$_.version -gt [System.Version]$CurrentVersion} | Where-Object status -eq 2 | Sort-Object -Property {[System.Version]$_.version} -Descending | Select-Object -First 1
}

if ($NewVersion) {

    $sourceUri = (Invoke-RestMethod $ApiUri/api/package/$($NewVersion.version)/link -Method Post -Headers $Headers).packageuri
    Write-Output "Source uri is $sourceUri"
}
else {
    Write-Output "Already on current version"
    exit
}

Write-Output "Proceeding with update to $($NewVersion.version)"

function Update-NME {
    param
    (
        [Parameter(Mandatory=$true)]
        [String] $sourceUri,
        [Parameter(Mandatory=$false)]
        [String] $azureEnv = "AzureCloud",
        [String] $subscriptionId,
        [String] $ResourceGroupName,
        [String] $WebAppName
    )

    Set-PSDebug -Strict
    $ErrorActionPreference = 'stop'

    $mgmtUri = "https://management.azure.com"
    $scmUriSiffix = ".scm.azurewebsites.net"

    if ($azureEnv -eq "AzureUSGovernment") {
        $mgmtUri = "https://management.usgovcloudapi.net"
        $scmUriSiffix = ".scm.azurewebsites.us"
    }

    function Get-AzCachedAccessToken()
    {
        $ErrorActionPreference = 'Stop'
        $azureRmProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
        if(-not $azureRmProfile.Accounts.Count) {
            Write-Error "Ensure you have logged in before calling this function."    
        }  
        $currentAzureContext = Get-AzContext
        $profileClient = New-Object Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient($azureRmProfile)
        Write-Debug ("Getting access token for tenant" + $currentAzureContext.Tenant.TenantId)
        $token = $profileClient.AcquireAccessToken($currentAzureContext.Tenant.TenantId)
        $token.AccessToken
    }

    function Get-AzBearerToken()
    {
        $ErrorActionPreference = 'Stop'
        ('Bearer {0}' -f (Get-AzCachedAccessToken))
    }

    function Get-AuthInfo {
        Param(
            [Parameter(Mandatory = $true)]
            [string]$SubscriptionId,
            [Parameter(Mandatory = $true)]
            [string]$ResourceGroupName,
            [Parameter(Mandatory = $true)]
            [string]$Name
        )
        $bearerToken = Get-AzBearerToken
        $apiUri = "$mgmtUri/subscriptions/"+ $SubscriptionId +"/resourceGroups/"+$ResourceGroupName+"/providers/Microsoft.Web/sites/"+$Name+"/publishxml?api-version=2016-08-01"
        $result = Invoke-RestMethod -Uri $apiUri -Headers @{Authorization=$bearerToken} -Method POST -ContentType "application/json" -Body @{format = "WebDeploy"}
        [xml]$publishSettings = $result.InnerXml
        $website = $publishSettings.SelectSingleNode("//publishData/publishProfile[@publishMethod='MSDeploy']")
        $username = $webSite.userName
        $password = $webSite.userPWD
        $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $username,$password)))
        return $base64AuthInfo
    }

    function Get-ApiUri  {
        Param(
            [Parameter(Mandatory = $true)]
            [string]$Name,
            [Parameter(Mandatory = $true)]
            [string]$Method
        )

        $apiUri ="https://" + $Name + $scmUriSiffix + "/api/" + $Method
        return $apiUri
    }

    function Start-WebAppJob  {
        Param(
            [Parameter(Mandatory = $true)]
            [string]$Name,
            [Parameter(Mandatory = $true)]
            [string]$AuthInfo
        )

        $apiUri = Get-ApiUri -Name $Name -Method "jobs/continuous/provision/start"
        Invoke-RestMethod -Uri $apiUri -Headers @{Authorization=("Basic {0}" -f $AuthInfo)} -Method Post -DisableKeepAlive -ContentType ''
    }

    function Stop-WebAppJob  {
        Param(
            [Parameter(Mandatory = $true)]
            [string]$Name,
            [Parameter(Mandatory = $true)]
            [string]$AuthInfo
        )

        $apiUri = Get-ApiUri -Name $Name -Method "jobs/continuous/provision/stop"
        Invoke-RestMethod -Uri $apiUri -Headers @{Authorization=("Basic {0}" -f $AuthInfo)} -Method Post -DisableKeepAlive -ContentType ''
    }

    function Publish-WebApp  {
        Param(
            [Parameter(Mandatory = $true)]
            [string]$ArchivePath,
            [Parameter(Mandatory = $true)]
            [string]$Name,
            [Parameter(Mandatory = $true)]
            [string]$AuthInfo
        )
    
        $apiUri = Get-ApiUri -Name $Name -Method "zipdeploy"
        $timeOutSec = 900
        Invoke-RestMethod -Uri $apiUri -Headers @{Authorization=("Basic {0}" -f $AuthInfo)} -Method PUT -InFile $ArchivePath -ContentType "multipart/form-data" -TimeoutSec $timeOutSec
    }

    function Invoke-CommandWithRetries {
        Param(
            [Parameter(Mandatory = $true)]
            [int]$MaxTries,
            [Parameter(Mandatory = $true)]
            [int]$SleepSeconds,
            [Parameter(Mandatory = $true)]
            [string]$ScriptName,
            [Parameter(Mandatory = $true)]
            [ScriptBlock]$ScriptToRun
        )

        $lastOutput = $null
        $success = $false
        for ($attempt = 1; ($attempt -le $MaxTries) -and !$success; $attempt++) {
            try {
                if ($attempt -ne 1) {
                    Write-Output "Sleep for $SleepSeconds seconds...`r`n"
                    Start-Sleep -Seconds $SleepSeconds
                }
                $lastOutput = Invoke-Command -ScriptBlock $ScriptToRun
                $success = $true
            } catch {
                Write-Output "$ScriptName atttempt $attempt of $MaxTries failed with exception:`r`n$($_.Exception.Message)`r`n"
            }
        }

        Write-Output @{
            Success = $success
            Output = $lastOutput
        }
    }

    function Start-AppServiceWithRetries {
        param (
            [Parameter(Mandatory = $true)]
            [string]$ResourceGroupName,
            [Parameter(Mandatory = $true)]
            [string]$Name,
            [Parameter(Mandatory = $true)]
            [int]$MaxTries,
            [Parameter(Mandatory = $true)]
            [int]$SleepSeconds
        )

        Write-Output "Starting App Service..."
        $startAppServiceResult = $null
        Invoke-CommandWithRetries -MaxTries $MaxTries -SleepSeconds $SleepSeconds -ScriptName "Start App Service" `
            -ScriptToRun { Start-AzWebApp -ResourceGroupName $ResourceGroupName -Name $Name } | `
            ForEach-Object { if ($_ -is [string]) { Write-Output $_ } else { $startAppServiceResult = $_ } }

        if ($startAppServiceResult.Success) {
            Write-Output "Successfully started App Service`r`n"
        } else {
            Write-Output "Failed to start App Service`r`n"
        }
        Write-Output $startAppServiceResult.Output
    }

    function Start-ProvisionWebJobWithRetries {
        param (
            [Parameter(Mandatory = $true)]
            [string]$AuthInfo,
            [Parameter(Mandatory = $true)]
            [string]$Name,
            [Parameter(Mandatory = $true)]
            [int]$MaxTries,
            [Parameter(Mandatory = $true)]
            [int]$SleepSeconds
        )

        Write-Output "Starting provision web job.."
        $startWebJobResult = $null
        Invoke-CommandWithRetries -MaxTries $MaxTries -SleepSeconds $SleepSeconds -ScriptName "Start provision web job" `
            -ScriptToRun { Start-WebAppJob -AuthInfo $AuthInfo -Name $Name }| `
            ForEach-Object { if ($_ -is [string]) { Write-Output $_ } else { $startWebJobResult = $_ } }

        if ($startWebJobResult.Success) {
            Write-Output "Successfully started provision web job`r`n"
        } else {
            Write-Output "Failed to start provision web job`r`n"
        }
        Write-Output $startWebJobResult.Output
    }

    function Publish-AppWithRetries {
        param (
            [Parameter(Mandatory = $true)]
            [string]$ArchivePath,
            [Parameter(Mandatory = $true)]
            [string]$Name,
            [Parameter(Mandatory = $true)]
            [string]$AuthInfo,
            [Parameter(Mandatory = $true)]
            [int]$MaxTries,
            [Parameter(Mandatory = $true)]
            [int]$SleepSeconds
        )

        Write-Output "Publishing..."
        $publishResult = $null
        Invoke-CommandWithRetries -MaxTries $MaxTries -SleepSeconds $SleepSeconds -ScriptName "Publish web app" `
            -ScriptToRun { Publish-WebApp -ArchivePath $ArchivePath -AuthInfo $AuthInfo -Name $Name -Verbose } | `
            ForEach-Object { if ($_ -is [string]) { Write-Output $_ } else { $publishResult = $_ } }

        if ($publishResult.Success) {
            Write-Output "Successfully published`r`n"
        } else {
            Write-Output "Failed to publish`r`n"
        }
        Write-Output $publishResult.Output
    }

    Write-Output "Downloading package"

    $packageZipPath = Join-Path -Path $env:TEMP -ChildPath ((New-Guid).ToString() + '.zip') 
    $packageDestPath = Join-Path -Path $env:TEMP -ChildPath (New-Guid)
    $packageDestVersionPath = Join-Path -Path $packageDestPath -ChildPath 'version.txt'
    $packageDestAppPath = Join-Path -Path $packageDestPath -ChildPath 'app.zip'
    $packageScriptsPath = Join-Path -Path $packageDestPath -ChildPath 'nwm-scripts.psm1'

    Invoke-WebRequest -Uri $sourceUri -OutFile $packageZipPath

    $size = (Get-Item -Path $packageZipPath).Length

    Write-Output "Package downloaded: $size bytes"

    Expand-Archive -Path $packageZipPath -DestinationPath $packageDestPath

    if (Test-Path -Path $packageDestVersionPath)
    {
        Write-Output "Package info"
        Get-Content -Path $packageDestVersionPath | Write-Output
    }

    Import-Module -Name $packageScriptsPath

    #$connection = Get-AutomationConnection -Name AzureRunAsConnection
    #Connect-AzAccount -ServicePrincipal -Tenant $connection.TenantID -ApplicationId $connection.ApplicationID -CertificateThumbprint $connection.CertificateThumbprint -Environment $azureEnv

    NWM-Before-Publish -rg $resourceGroupName -appName $webAppName

    Write-Output "Get App Service $webAppName"
    $appService = Get-AzWebApp -ResourceGroupName $resourceGroupName -Name $webAppName
    $appService

    $authInfo = Get-AuthInfo -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -Name $webAppName

    Write-Output "Stopping provision web job.."
    $stopprovisionWebJobResult = $null
    Invoke-CommandWithRetries -MaxTries 5 -SleepSeconds 30 -ScriptName "Stop provision web job" `
        -ScriptToRun { Stop-WebAppJob -AuthInfo $authInfo -Name $webAppName } | `
        ForEach-Object { if ($_ -is [string]) { Write-Output $_ } else { $stopprovisionWebJobResult = $_ } }

    if (!$stopprovisionWebJobResult.Success) {
        Write-Output "Failed to stop provision web job, trying to start it back"

        Start-ProvisionWebJobWithRetries -AuthInfo $authInfo -Name $webAppName -MaxTries 3 -SleepSeconds 30
    
        throw "Failed to stop provision web job"
    } else {
        Write-Output "Successfully stopped provision web job`r`n"
        Write-Output $stopprovisionWebJobResult.Output
    }


    Write-Output "Stopping web app..."
    $stopWebAppResult = $null
    Invoke-CommandWithRetries -MaxTries 5 -SleepSeconds 30 -ScriptName "Stop web app" `
        -ScriptToRun { Stop-AzWebApp -ResourceGroupName $resourceGroupName -Name $webAppName } | `
        ForEach-Object { if ($_ -is [string]) { Write-Output $_ } else { $stopWebAppResult = $_ } }

    if (!$stopWebAppResult.Success) {
        Write-Output "Failed to stop web app, trying to start App Service and provision web job"

        Start-AppServiceWithRetries -ResourceGroupName $resourceGroupName -Name $webAppName -MaxTries 3 -SleepSeconds 30

        Start-ProvisionWebJobWithRetries -AuthInfo $authInfo -Name $webAppName -MaxTries 3 -SleepSeconds 30
    
        throw "Failed to stop web app"
    } else {
        Write-Output "Successfully stopped web app`r`n"
        Write-Output $stopWebAppResult.Output
    }

    Publish-AppWithRetries -ArchivePath $packageDestAppPath -AuthInfo $authInfo -Name $webAppName -MaxTries 5 -SleepSeconds 30

    Start-AppServiceWithRetries -ResourceGroupName $resourceGroupName -Name $webAppName -MaxTries 5 -SleepSeconds 30

    Start-ProvisionWebJobWithRetries -AuthInfo $authInfo -Name $webAppName -MaxTries 5 -SleepSeconds 30

    NWM-After-Publish -rg $resourceGroupName -appName $webAppName
}

Update-NME -sourceUri $sourceUri -azureEnv $azureEnv -subscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -WebAppName $webAppName 