#description: (PREVIEW) Create a working AVD environment with desktop image and autoscale host pool
#tags: Nerdio, Preview

<#

This script creates a working AVD environment, including:
 - AVD Workspace
 - Desktop Image
 - Dynamic Host Pool with Autoscale enabled
 - Assigns users to host pool

NOTE: the created Workspace will not be visible in NMW until you set 
"Hide Unassigned Workspaces" to OFF in the settings of Workspaces page

This script requires the NME API to be enabled, under settings -> Nerdio Integrations

Before running this script, set the Required Variables to your own values. 

You may also wish to look over the Additional Variables section and make any necessary changes 
from the defaults specified here.

#>


##### Required Variables #####

$client_secret = $SecureVars.ClientSecret # Set this variable in NMW under Settings -> Nerdio Integrations
$app_url = '' # no trailing slash
$client_id = ''
$scope = ''
$tenant_id =''

$SubscriptionId = ''
$ResourceGroupName = ''

$VnetName = ''
$NetworkResourceGroupName = ''
$SubnetName = '' # subnet where AVD hosts will be provisioned
$RegionName = "" # e.g. "eastus2"


##### Additional Variables #####

$WindowsVersion = 'microsoftwindowsdesktop/office-365/win11-24h2-avd-m365/latest' # Version of windows to use in desktop image and host pool
$ImageVmSize = 'Standard_D2as_v4'

$WorkspaceName = "" # Make sure you don't use spaces!
$WorkspaceFriendlyName = "Windows 11 Remote Desktop"
$WorkspaceDescription = "Access to your personal Windows 11 remote desktop"
$AdConfigId = $null # The id of the AD Configuration to use for the desktop image and host pool VMs. Will use the default config if none specified.


$DesktopImageName = "" #No spaces!
$ImageStorageType = 'StandardSSD_LRS'

$TimeZone = "Eastern Standard Time"

$HostPoolName = "" #No spaces!
$HostPoolDescription = ""
$ScriptedActionIDs = @() # List of Scripted Actions (by id) to be run on the image. Can be used to install software. E.g.: $ScriptedActionIDs = @(35, 36)

$UserUPNs = @() # Users to assign to the new host pool. E.g.: $UserUPNs =  @('first_user@domain.com', 'second_user@domain.com', 'third_user@domain.com')

$HostVmPrefix = "AVD"
$HostVmSize = "Standard_D16as_v4"
$HostVmStorageType = 'Premium_LRS'
$HostVmDiskSize = 128
$hasEphemeralOSDisk = $false
$BaseHostPoolCapacity = 1
$MinActiveHostsCount = 1
$BurstCapacity = 2

#####

##### Script Logic #####

$errorActionPreference = "Stop" 

$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$headers.Add("Content-Type", "application/x-www-form-urlencoded")

$encoded_scope = [System.Web.HTTPUtility]::UrlEncode("$Scope")

$body = "grant_type=client_credentials&client_id=$client_id&scope=$encoded_scope&client_secret=$client_secret"

$TokenResponse = Invoke-RestMethod "https://login.microsoftonline.com/$tenant_id/oauth2/v2.0/token" -Method POST -Headers $headers -Body $body

$token = $TokenResponse.access_token

$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$headers.Add("Authorization", "Bearer $token")
$headers.Add("Accept", "application/json")
$headers.Add("Content-Type", "application/json")


if (!$AdConfigId){
    $AdConfigs = Invoke-RestMethod -Uri "$app_url/api/v1/ad/config" -Method Get -UseBasicParsing -Headers $headers
    $AdConfigId = ($AdConfigs | Where-Object isDefault -eq $true).id
} 

$NewWorkspaceBody = @"
{
  "id": {
    "subscriptionId": "$SubscriptionId",
    "resourceGroup": "$ResourceGroupName",
    "name": "$WorkspaceName"
  },
  "location": "$RegionName",
  "friendlyName": "$WorkspaceFriendlyName",
  "description": "$WorkspaceDescription"
}
"@

$NewWorkspace = Invoke-RestMethod "$app_url/api/v1/workspace" -Headers $headers -Body $NewWorkspaceBody -Method Post -UseBasicParsing 




$NewDesktopImageBody = @"
{
 "jobPayload": {
		"imageId": {
            "subscriptionId": "$SubscriptionId",
            "resourceGroup": "$ResourceGroupName",
            "name": "$DesktopImageName"
        },
        "sourceImageId": "$WindowsVersion",
        "vmSize": "$ImageVmSize",
        "storageType": "$ImageStorageType",
        "diskSize": 128,
        "networkId": "/subscriptions/$SubscriptionId/ResourceGroups/$NetworkResourceGroupName/providers/Microsoft.Network/virtualNetworks/$VnetName",
        "subnet": "$SubnetName",
        "description": "image description",
        "noImageObjectRequired": false,
        "enableTimezoneRedirection": true,
        "vmTimezone": "Eastern Standard Time",
        "scriptedActionsIds": $(if ($ScriptedActionIDs){$ScriptedActionIDs | ConvertTo-Json} else{'null'})
    },
    "failurePolicy": {
        "restart": true,
        "cleanup": true
    }
}
"@

$NewDesktopImage = Invoke-RestMethod "$app_url/api/v1/desktop-image/create-from-library" -Method 'POST' -Headers $headers -Body $NewDesktopImageBody 

# Get status of job
$NewDesktopImageStatus = Invoke-RestMethod "$app_url/api/v1/job/$($NewDesktopImage.job.id)" -Method Get -Headers $headers 

while ($NewDesktopImageStatus.jobStatus -eq 'Pending' -or $NewDesktopImageStatus.jobStatus -eq 'Running')
{
    Sleep 60
    $NewDesktopImageStatus = Invoke-RestMethod "$app_url/api/v1/job/$($NewDesktopImage.job.id)" -Method Get -Headers $headers 
}

if ($NewDesktopImageStatus.jobStatus -eq 'Failed') {
    Throw "Error creating desktop image"
}



$NewHostPoolBody = @"
{
  "workspaceId": {
    "subscriptionId": "$SubscriptionId",
    "resourceGroup": "$ResourceGroupName",
    "name": "$WorkspaceName"
  },
  "pooledParams": {
    "isDesktop": true,
    "isSingleUser": false
  },
  "description": "$HostPoolDescription"
}
"@

$NewHostPool = Invoke-RestMethod "$app_url/api/v1/arm/hostpool/$SubscriptionId/$ResourceGroupName/$HostPoolName" -Method Post -Headers $headers -Body $NewHostPoolBody


$ConvertToDynamic = Invoke-RestMethod "$app_url/api/v1/arm/hostpool/$SubscriptionId/$ResourceGroupName/$HostPoolName/auto-scale" -Method Post -Headers $headers 

if ($UserUPNs)
{
    $AssignUserBody = @"
    {
        "users": $($UserUPNs | ConvertTo-Json)
    }
"@

    Invoke-RestMethod "$app_url/api/v1/arm/hostpool/$SubscriptionId/$ResourceGroupName/$HostPoolName/assign" -Method Post -Headers $headers -body $AssignUserBody

}
$AutoScaleEnableBody = @"
{
    "isEnabled": true
    }
 
"@

Invoke-RestMethod "$app_url/api/v1/arm/hostpool/$SubscriptionId/$ResourceGroupName/$HostPoolName/auto-scale" -Method Patch -Headers $headers -Body $AutoScaleEnableBody
$AutoScaleConfigBody = @"
{
    "isEnabled": true,
    "timezoneId" : "Eastern Standard Time",
    "vmTemplate": {
        "prefix": "$HostVmPrefix",
        "size": "$HostVmSize",
        "image": "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Compute/virtualmachines/$DesktopImageName",
        "storageType": "$HostVmStorageType",
        "resourceGroupId": "$((Get-AzResourceGroup -Name $ResourceGroupName).resourceid)",
        "networkId": "$((Get-AzVirtualNetwork -Name $vnetname -ResourceGroupName $NetworkResourceGroupName).id)",
        "subnet": "$SubnetName",
        "diskSize": $HostVmDiskSize,
        "hasEphemeralOSDisk": $($hasEphemeralOSDisk | ConvertTo-Json)
    },
    "stoppedDiskType": null,
    "reuseVmNames": true,
    "enableFixFailedTask": true,
    "isSingleUserDesktop": false,
    "activeHostType": "Running",
    "minCountCreatedVmsType": "HostPoolCapacity",
    "scalingMode": "Default",
    "hostPoolCapacity": $BaseHostPoolCapacity,
    "minActiveHostsCount": $MinActiveHostsCount,
    "burstCapacity": $BurstCapacity,
    "autoScaleCriteria":  "CPUUsage",
    "scaleInAggressiveness":  "Low",
    "workingHoursScaleOutBehavior":  null,
    "workingHoursScaleInBehavior":  null,
    "hostUsageScaleCriteria":  {
        "scaleOut":  {
                        "averageTimeRangeInMinutes":  5,
                        "hostChangeCount":  1,
                        "value":  65,
                        "collectAlways":  true
                    },
        "scaleIn":  {
                        "averageTimeRangeInMinutes":  15,
                        "hostChangeCount":  1,
                        "value":  40,
                        "collectAlways":  true
                    }
                                },
    "activeSessionsScaleCriteria":  {
        "scaleOut":  {
                            "hostChangeCount":  1,
                            "value":  1,
                            "collectAlways":  true
                        },
        "scaleIn":  {
                        "hostChangeCount":  1,
                        "value":  0,
                        "collectAlways":  true
                    }
    },
    "availableUserSessionsScaleCriteria":  {
        "maxSessionsPerHost":  null,
        "minAvailableUserSessions":  1,
        "maxAvailableUserSessions":  1,
        "availableSessionRestriction":  "Always",
        "outsideWorkHoursSessions":  null
    },
    "scaleInRestriction":  {
        "enable":  false,
        "timeRange":  null
    },
    "preStageHosts":  {
                            "enable":  false,
                            "config":  null
                        },
    "removeMessaging":  {
                            "minutesBeforeRemove":  10,
                            "message":  "Sorry for the interruption. We are doing some housekeeping and need you to log out. You can log in right away to continue working. We will be terminating your session in 10 minutes if you haven\u0027t logged out by then."
                        },
    "autoHeal":  {
                        "enable":  false,
                        "config":  null
                    }
}
"@

Invoke-RestMethod "$app_url/api/v1/arm/hostpool/$SubscriptionId/$ResourceGroupName/$HostPoolName/auto-scale" -Method Put -Headers $headers -Body $AutoScaleConfigBody


$ASconfig = Invoke-RestMethod "$app_url/api/v1/arm/hostpool/$SubscriptionId/$ResourceGroupName/$HostPoolName/auto-scale" -Method Get -Headers $headers
    $RDPConfigBody = @"
{
  "configurationName": null,
  "rdpProperties": "drivestoredirect:s:*;audiomode:i:0;videoplaybackmode:i:1;redirectclipboard:i:1;redirectprinters:i:1;devicestoredirect:s:*;redirectcomports:i:1;redirectsmartcards:i:1;usbdevicestoredirect:s:*;enablecredsspsupport:i:1;redirectwebauthn:i:1;use multimon:i:1;enablerdsaadauth:i:1;autoreconnection enabled:i:1;bandwidthautodetect:i:1;networkautodetect:i:1;compression:i:1;audiocapturemode:i:1;encode redirected video capture:i:1;redirected video capture encoding quality:i:1;camerastoredirect:s:*;redirectlocation:i:1;targetisaadjoined:i:1"
}
"@
Invoke-RestMethod "$app_url/api/v1/arm/hostpool/$SubscriptionId/$ResourceGroupName/$HostPoolName/rdp" -Method Put -Headers $headers -Body $RDPConfigBody
$RDPConfig = Invoke-RestMethod "$app_url/api/v1/arm/hostpool/$SubscriptionId/$ResourceGroupName/$HostPoolName/rdp" -Method Get -Headers $headers
