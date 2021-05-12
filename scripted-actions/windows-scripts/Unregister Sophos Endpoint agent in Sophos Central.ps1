#description: Unregisters endpoint agent from Sophos Central using API.
#tags: Nerdio, Sophos
<#
Notes:
IMPORTANT: Refer to the Sophos Integration Article for instructions on how to use this script!
https://nmw.zendesk.com/hc/en-us/articles/1500004124602

This script uses the Sophos API to delete the associated VM from Sophos Central.
Please refer to sophos documentation for more information:
https://developer.sophos.com/intro
https://developer.sophos.com/docs/endpoint-v1/1/overview
#>

# Enable Logging
$SaveVerbosePreference = $VerbosePreference
$VerbosePreference = 'continue'
$VMTime = Get-Date
$LogTime = $VMTime.ToUniversalTime()
mkdir "C:\Windows\temp\NMWLogs\ScriptedActions\sophosunregister" -Force
Start-Transcript -Path "C:\Windows\temp\NMWLogs\ScriptedActions\sophosunregister\ps_log.txt" -Append
Write-Host "################# New Script Run #################"
Write-host "Current time (UTC-0): $LogTime"

# Pass in secure variables from NMW
$ClientID     = $SecureVars.sophosclientid
$ClientSecret = $SecureVars.sophosclientsecret
$TenantID     = $SecureVars.sophostenantid
$APIHost      = $SecureVars.sophosapihost

# Error out if required secure variables are not passed
if(!$ClientID -or !$ClientSecret){
    Write-Error "ERROR: Required variables sophosclientiD and/or sophosclientSecret are not being passed from NMW. Please add these secure variables" -ErrorAction Stop

}

# Authenticate and get Bearer Token
$AuthBody = @{
    grant_type = "client_credentials"
    client_id = $ClientID
    client_secret = $ClientSecret
    scope = "token"
}
Write-Output "INFO: Retrieving Auth Info using Client Secrets"
$AuthResponse = (Invoke-RestMethod -Method 'post' -Uri 'https://id.sophos.com/api/v2/oauth2/token' -Body $AuthBody)
$AuthToken = $AuthResponse.access_token
$AuthHeaders = @{Authorization = "Bearer $AuthToken"}

$WhoAmIResponse = (Invoke-RestMethod -Method 'get' -headers $AuthHeaders -Uri 'https://api.central.sophos.com/whoami/v1' -UseBasicParsing)
if(!$TenantID -and !$APIHost){
    # Get Tenant info and APIHost/ if not specified 
    Write-Output 'INFO: Retrieving Tenant ID and APIHost/Data Region'
    $APIHost = $WhoAmIResponse.apihosts.dataRegion
    $TenantID = $WhoAmIResponse.id
}
else{
    if($WhoAmIResponse.idtype -ne "tenant"){
        Write-Error "ERROR: The API Client credentials given are not for a Tenant and the Tenant ID and API Host values were not specified." -ErrorAction Stop
    }
}

# Query for endpoint with hostname that matches Azure VM name, get endpoint ID
$TenantsHeader = @{
    'Authorization' = "Bearer $AuthToken"
    'X-Tenant-ID' = $TenantID
}
Write-Output "INFO: Searching registered endpoints for matching VM hostname"
$EndpointResponse = (Invoke-RestMethod -Method 'get' -Headers $TenantsHeader -uri "$APIHost/endpoint/v1/endpoints?hostnameContains=$AzureVMName" -UseBasicParsing)
if(!$EndpointResponse.items){
    Write-Host "ERROR: No endpoints found in sophos central that match the hostname. Ending script"
    exit
}
# Sophos API can return multiple endpoints, the hostname search is not strict. Go through results and get exact match
foreach($Endpoint in ($EndpointResponse.items)){ 
    if($Endpoint.Hostname -match "$AzureVMName"){
        $EndpointID = $Endpoint.id
        Write-Output "INFO: Found Endpoint ID: $EndpoindID"
    }
}

# Send DELETE request to Sophos API and provide endpoint ID
Write-Output "INFO: Attempting to Delete $AzureVMName from Sophos Central"
$DeleteResponse = (Invoke-RestMethod -Method 'delete' -Headers $TenantsHeader -uri "$APIHost/endpoint/v1/endpoints/$EndpointID" -UseBasicParsing)

# Check if request was successful
Write-Output "INFO: Checking response to confirm deletion"
Start-Sleep -Seconds 15
if($DeleteResponse.deleted = "true"){
    Write-Output "INFO: Successfully deleted $AzureVMName from Sophos Central"
}
else {
    Write-Output "Error: Unable to delete endpoint from Sophos Central"
}

# End Logging
Stop-Transcript
$VerbosePreference=$SaveVerbosePreference
