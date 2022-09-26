#description: (PREVIEW) Creates a temp vm which is used to shrink FSLogix profiles
#tags: Nerdio, Preview

<#
Notes:


#>

<# Variables:
{
  "CurrentImage": {
    "Description": "",
    "IsRequired": true
  },
  "NewImage": {
    "Description": "",
    "IsRequired": true
  },
  "UpdateScheduledReimage": {
    "Description": "",
    "IsRequired": false
  }
}
#>


$ErrorActionPreference = 'Stop'

##### Retrieve Secure Variables #####

$script:ClientId = $SecureVars.NerdioApiClientId
$script:Scope = $SecureVars.NerdioApiScope
$script:ClientSecret = $SecureVars.NerdioApiClientSecret

##### Get Nerdio Environment Information #####

$AppServiceName = $KeyVaultName -replace '-kv',''
[string]$script:TenantId = (Get-AzKeyVault -VaultName $KeyVaultName).TenantId
$script:NerdioUri = "https://$AppServiceName.azurewebsites.net"

#####


function Set-NerdioAuthHeaders {

    if ($Script:AuthHeaders -eq $null -or $Script:TokenCreationTime -lt (get-date).AddSeconds(-3599)){
        Write-Verbose "Renewing token"
        $body = "grant_type=client_credentials&client_id=$ClientId&scope=$Scope&client_secret=$ClientSecret"
        $response = Invoke-RestMethod "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Method 'POST' -Body $body
        $Script:TokenCreationTime = get-date
        $script:AuthHeaders = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
        $script:AuthHeaders.Add("Authorization", "Bearer $($response.access_token)")
    }


}

function Get-NerdioHostPoolAutoScale {
    Param (
        [string]$HostPoolName,
        [guid]$SubscriptionId,
        [string]$ResourceGroupName
    )
    Set-NerdioAuthHeaders
    $HostPool = Invoke-RestMethod "$script:NerdioUri/api/v1/arm/hostpool/$SubscriptionId/$ResourceGroupName/$HostPoolName/auto-scale" -Method Get -Headers $script:AuthHeaders

    $HostPool
}

function Set-NerdioHostPoolAutoScale {
    Param (
        [string]$HostPoolName,
        [guid]$SubscriptionId,
        [string]$ResourceGroupName,
        [psobject]$AutoscaleSettings
    )
    Set-NerdioAuthHeaders
    $json = $AutoscaleSettings | ConvertTo-Json -Depth 10
    $HostPool = Invoke-RestMethod "$script:NerdioUri/api/v1/arm/hostpool/$SubscriptionId/$ResourceGroupName/$HostPoolName/auto-scale" -Method put -Headers $script:AuthHeaders -Body $json -ContentType 'application/json'

    $HostPool
}

Set-NerdioAuthHeaders -ClientId $ClientId -ClientSecret $ClientSecret -TenantId $TenantId -Scope $Scope

$HostPools = Get-AzWvdHostPool
$images =@()
foreach ($hp in $HostPools) {
    $SubscriptionId = ($hp.id -split '/')[2]
    $ResourceGroupName = ($hp.id -split '/')[4]
    Write-Verbose "Getting auto-scale settings for host pool $($hp.name)"
    $HpAs = Get-NerdioHostPoolAutoScale -HostPoolName $hp.name -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName
    $images += $HpAs.vmTemplate.image
    <#
    if ($HpAs.vmTemplate.image -eq $CurrentImage){
        Write-Output "Host pool auto-scale is using current image. Changing to new image."
        $HpAs.vmTemplate.image = $NewImage
        Set-NerdioHostPoolAutoScale -HostPoolName $hp.name -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -AutoscaleSettings $HpAs
    }
    #>
}