#description: (PREVIEW) Replaces all instances of CurrentImage with NewImage in host pools and scheduled reimage tasks
#tags: Nerdio, Preview

<#
Notes:

This script requires the Nerdio REST API to be enabled (in Settings->Integrations), and the following
Secure Variables must be configured and assigned to this scripted action in Settings->Nerdio Environment:

nerdioAPIClientId
nerdioAPIKey
nerdioAPIScope
nerdioAPITenantId
nerdioAPIUrl

The CurrentImage and NewImage parameters require the full resource id of the Azure image or VM.

If using an image based on a VM (such as a Nerdio Desktop Image VM), the format will looks like: 
/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourcegroups/your-resource-group/providers/microsoft.compute/virtualmachines/yourVm

If using an image from Azure compute images, the format will look like this:
/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourcegroups/your-resource-group/providers/microsoft.compute/images/yourImage

If using an image from an image gallery, the format will look like this:
/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourcegroups/your-resource-group/providers/microsoft.compute/galleries/your-image-gallery/images/yourImage

If using a marketplace image, the format will look like this (with no leading slash)
microsoftwindowsdesktop/windows-10/21h1-ent-g2/latest

This script may not work on subscriptions that were linked via a Client App registration

#>

<# Variables:
{
  "CurrentImage": {
    "Description": "Full name of current image. See Notes section of script for examples.",
    "IsRequired": false
  },
  "NewImage": {
    "Description": "Full name of new image. See Notes section of script for examples.",
    "IsRequired": false
  },
  "UpdateScheduledReimage": {
    "Description": "Update any scheduled reimage jobs using CurrentImage to use NewImage",
    "IsRequired": false,
    "DefaultValue": "True"
  },
  "ReportOnly": {
    "Description": "Set to True to display a list of host pools that will be updated. Will not make any changes to current configuration",
    "IsRequired": false,
    "DefaultValue": "False"
  }
}
#>


$ErrorActionPreference = 'Stop'

##### Retrieve Secure Variables #####

$script:ClientId = $SecureVars.NerdioApiClientId
$script:Scope = $SecureVars.NerdioApiScope
$script:ClientSecret = $SecureVars.NerdioApiKey
$script:TenantId = $SecureVars.NerdioAPITenantId
$script:NerdioUri = $SecureVars.NerdioAPIUrl
$script:ReportOnly = [System.Convert]::ToBoolean($ReportOnly)

#####


function Set-NerdioAuthHeaders {
    [CmdletBinding()]
    param([switch]$Force)
    if ($null -eq $Script:AuthHeaders -or ($Script:TokenCreationTime -lt (get-date).AddSeconds(-3599)) -or $Force){
        Write-Verbose "Renewing token"
        $body = "grant_type=client_credentials&client_id=$ClientId&scope=$Scope&client_secret=$ClientSecret"
        try {
            $response = Invoke-RestMethod "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Method 'POST' -Body $body
        }
        catch {
            $message = ParseErrorForResponseBody($_)
            write-error $message
        }
        $Script:TokenCreationTime = get-date
        $script:AuthHeaders = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
        $script:AuthHeaders.Add("Authorization", "Bearer $($response.access_token)")
    }


}

function Get-NerdioLinkedResourceGroups {
    [CmdletBinding()]
    Param()
    Set-NerdioAuthHeaders
    try {
        $RGs = Invoke-RestMethod "$script:NerdioUri/api/v1/resourcegroup" -Method Get -Headers $script:AuthHeaders -UseBasicParsing
        $RGs
    }
    catch {
        $message = ParseErrorForResponseBody($_)
        write-error $message
    }
}

function Get-NerdioHostPoolAutoScale {
    [CmdletBinding()]
    Param (
        [string]$HostPoolName,
        [guid]$SubscriptionId,
        [string]$ResourceGroupName
    )
    Set-NerdioAuthHeaders
    try {
        $HostPool = Invoke-RestMethod "$script:NerdioUri/api/v1/arm/hostpool/$SubscriptionId/$ResourceGroupName/$HostPoolName/auto-scale" -Method Get -Headers $script:AuthHeaders -UseBasicParsing
        $HostPool
    }
    catch {
        $message = ParseErrorForResponseBody($_)
        write-error $message
    }
}

function Set-NerdioHostPoolAutoScale {
    [CmdletBinding()]
    Param (
        [string]$HostPoolName,
        [guid]$SubscriptionId,
        [string]$ResourceGroupName,
        [psobject]$AutoscaleSettings
    )
    Set-NerdioAuthHeaders
    $json = $AutoscaleSettings | ConvertTo-Json -Depth 20
    $json | Write-Verbose
    if ($AutoscaleSettings.autoscaleTriggers.triggertype -eq 'PersonalAutoShrink') {
        $uri = "$script:NerdioUri/api/v1/arm/hostpool/$SubscriptionId/$ResourceGroupName/$HostPoolName/auto-scale?multiTriggers=true"
    }
    else {
        $uri = "$script:NerdioUri/api/v1/arm/hostpool/$SubscriptionId/$ResourceGroupName/$HostPoolName/auto-scale"
    }
    try {
        $HostPool = Invoke-RestMethod "$uri" -Method put -Headers $script:AuthHeaders -Body $json -ContentType 'application/json' -UseBasicParsing 
        $HostPool
    }
    catch {
        $message = ParseErrorForResponseBody($_)
        write-error $message
    }
}

function Get-NerdioHostPoolScheduledReimage {
    [CmdletBinding()]
    Param(
        [string]$HostPoolName,
        [guid]$SubscriptionId,
        [string]$ResourceGroupName
    )
    Set-NerdioAuthHeaders

    try {
        $ReimageJob = Invoke-RestMethod "$script:NerdioUri/api/v1/arm/hostpool/$SubscriptionId/$ResourceGroupName/$HostPoolName/schedule/reimage/job-params" -Method get -Headers $script:AuthHeaders -ContentType 'application/json'
        $ReimageJob
    }
    catch {
        $message = ParseErrorForResponseBody($_)
        write-error $message
    }
}

function Set-NerdioHostPoolScheduledReimage {
    [CmdletBinding()]
    Param(
        [string]$HostPoolName,
        [guid]$SubscriptionId,
        [string]$ResourceGroupName,
        [psobject]$ScheduledReimageParams
    )
    Set-NerdioAuthHeaders
    $json = $ScheduledReimageParams | ConvertTo-Json -Depth 20
    Write-Verbose "json:"
    Write-Verbose $json 
    try {
        $SetReimageJob = Invoke-RestMethod "$script:NerdioUri/api/v1/arm/hostpool/$SubscriptionId/$ResourceGroupName/$HostPoolName/schedule/reimage" -Method Post -Headers $script:AuthHeaders -Body $json -ContentType 'application/json'
        $SetReimageJob
    }
    catch {
        $message = ParseErrorForResponseBody($_)
        write-error $message
    }
}

function Convertto-NerdioScheduledReimageParams{
    [CmdletBinding()]
    Param([Parameter(Mandatory=$true,ValueFromPipeline=$true)][psobject]$ReimageJob)

    if ($ReimageJob.bulkJobParams.globalTimeoutInMinutes ) {
        $TimeoutInDays = $ReimageJob.bulkJobParams.globalTimeoutInMinutes / 60 / 24
    }
    else {$TimeoutInDays = $null}

    $ReimageParams = @{
        image = $ReimageJob.jobParams.image
        vmSize = $ReimageJob.jobParams.vmSize
        storageType = $ReimageJob.jobParams.storageType
        diskSize = $ReimageJob.jobParams.diskSize 
        hasEphemeralOSDisk = $ReimageJob.jobParams.hasEphemeralOSDisk
        setToDrainModeWhileProcessing = $ReimageJob.jobParams.setToDrainModeWhileProcessing
        ephemeralOSDiskPlacement = $ReimageJob.jobParams.ephemeralOSDiskPlacement 
    }
    $Concurrency = @{
        tasks = $ReimageJob.bulkJobParams.taskParallelism 
        maxFailedTasks = $ReimageJob.bulkJobParams.countFailedTaskToStopWork 
    }
    $Messaging = @{
        message = $ReimageJob.bulkJobParams.message 
        delayMinutes = $ReimageJob.bulkJobParams.minutesBeforeRemove 
        logOffAggressiveness = $ReimageJob.bulkJobParams.logOffAggressiveness 
        deactivateBeforeOperation = $ReimageJob.bulkJobParams.deactivateBeforeOperation 
        timeoutInDays = $TimeoutInDays
    }
    $Schedule = @{
        startDate = $ReimageJob.schedule.startDate 
        startHour = $ReimageJob.schedule.startHour 
        startMinutes = $ReimageJob.schedule.startMinutes
        timeZoneId = $ReimageJob.schedule.timeZoneId  
        scheduleRecurrenceType = $ReimageJob.schedule.scheduleRecurrenceType
        dayOfWeekNumber = $ReimageJob.schedule.dayOfWeekNumber 
        dayOfWeek = $ReimageJob.schedule.dayOfWeek  
        offsetInDays = $ReimageJob.schedule.offsetInDays 
    }
    $Reimage = @{reimageParams = $ReimageParams; concurrency = $Concurrency; messaging = $messaging}
    $Parameters = @{reimage = $Reimage; schedule = $Schedule}
    $Parameters 

}

function ParseErrorForResponseBody($ErrorObj) {
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        if ($ErrorObj.Exception.Response) {  
            $Reader = New-Object System.IO.StreamReader($ErrorObj.Exception.Response.GetResponseStream())
            $Reader.BaseStream.Position = 0
            $Reader.DiscardBufferedData()
            $ResponseBody = $Reader.ReadToEnd()
            if ($ResponseBody.StartsWith('{')) {
                $ResponseBody = $ResponseBody | ConvertFrom-Json
            }
            return $ResponseBody.errormessage
        }
    }
    else {
        return $ErrorObj.ErrorDetails.Message
    }
}

Set-NerdioAuthHeaders -Force

Write-Output "Getting Nerdio RGs"
$NerdioResourceGroups = Get-NerdioLinkedResourceGroups 
Write-Output "Getting subscriptions"
$subs = Get-AzSubscription

if (!$ReportOnly) {Write-output "The following host pools are being updated:"}
else {Write-Output "The following host pools would be updated by this script. No changes will be made at this time."}

foreach ($sub in $subs) {
    Select-AzSubscription -SubscriptionObject $sub | Out-Null
    Write-Verbose "Getting azure resource groups"
    $AzResourceGroups = Get-AzResourceGroup 
    $ResourceGroups = $NerdioResourceGroups | Where-Object name -in $AzResourceGroups.ResourceGroupName
    Write-Output "Subscription: $($sub.Name)"
    $HostPools = $ResourceGroups | select name -ExpandProperty name | ForEach-Object {Get-AzWvdHostPool -ResourceGroupName $_}

    foreach ($hp in $HostPools) {
        $SubscriptionId = ($hp.id -split '/')[2]
        $ResourceGroupName = ($hp.id -split '/')[4]
        Write-Verbose "Getting auto-scale settings for host pool $($hp.name)"
        try {
            $HpAs = Get-NerdioHostPoolAutoScale -HostPoolName $hp.name -SubscriptionId $sub.id -ResourceGroupName $ResourceGroupName 
        }
        catch {
            if ($_.exception.message -match 'not found'){
                Write-Verbose "Host pool $($hp.name) not found in NME. Continuing."
                continue
            }
            else {
                Write-Error  "Unable to retrieve host pool settings for $($hp.name). Recieved error $($_.exception.message)" -ErrorAction Continue
                continue
            }
        }
    
        if ($HpAs.vmTemplate.image -eq $CurrentImage){
            Write-Output "$($hp.name) - AutoScale using current image."
            $HpAs.vmTemplate.image = $NewImage
            if (!$ReportOnly) {
                try {
                    Write-Output "$($hp.name) - updating image."
                    $UpdateAS = Set-NerdioHostPoolAutoScale -HostPoolName $hp.name -SubscriptionId $sub.id -ResourceGroupName $ResourceGroupName -AutoscaleSettings $HpAs 
                }
                catch {
                    Write-Output "Error updaing host pool settings for $($hp.name). Error is $($_.exception.message)"
                    Write-Error "Error updaing host pool settings for $($hp.name). Error is $($_.exception.message)" -ErrorAction Continue
                }
            }
        }
        else {
            Write-Verbose "Host pool $($hp.name) is not using current image"
        }
        if ([System.Convert]::ToBoolean($UpdateScheduledReimage)){
            try {
                $ReimageJob = Get-NerdioHostPoolScheduledReimage -HostPoolName $hp.name -SubscriptionId $sub.id -ResourceGroupName $ResourceGroupName 
            }
            catch {
                if ($_.exception.message -match 'not found'){
                    Write-Verbose "No scheduled reimage job for hp $($hp.name)."
                    continue
                }
                else {
                    Write-Error  "Unable to retrieve reimage job settings for $($hp.name). Recieved error $($_.exception.message)" -ErrorAction Continue
                    continue
                }
            }
            if ($ReimageJob.jobParams.image -eq $CurrentImage) {
                Write-Output "$($hp.name) - scheduled reimage using current image."
                if (!$ReportOnly) {
                    Write-Output "$($hp.name) - updating scheduled reimage."
                    $ReimageJob.jobParams.image = $NewImage
                    $ScheduledReimageParams = $ReimageJob | Convertto-NerdioScheduledReimageParams
                    try { 
                        Set-NerdioHostPoolScheduledReimage -HostPoolName $hp.name -SubscriptionId $sub.id -ResourceGroupName $ResourceGroupName -ScheduledReimageParams $ScheduledReimageParams
                    }
                    catch {
                        Write-Error "Unable to update scheduled reimage job for host pool $($hp.name). $($_.exception.message)" -ErrorAction Continue
                    }
                }
            }
        }
    }
}
