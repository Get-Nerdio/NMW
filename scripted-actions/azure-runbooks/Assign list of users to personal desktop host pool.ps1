#description: Add a comma-separated list of users to a host pool
#tags: Nerdio, Preview

<# Notes:
    This scripted action assigns a list of users to a personal desktop host pool. The script will
    assign one user to each host in the pool. If there are more users than hosts, users will be assigned
    until there are no hosts left.
    
    This scripted action cannot currently be started on a host pool in Nerdio Manager. Instead, start
    this script from the scripted actions screen in Nerdio, and specify the host pool name in the 
    parameters. Additionally supply a comma-separated list of fully qualified usernames (UPNs) to be 
    assigned to the host pool. E.g.: jlennon@contoso.com, pmccartney@contoso.com
#>

<# Variables:
{
  "HostPoolName": {
    "Description": "Name of Host Pool",
    "IsRequired": true,
    "DefaultValue": ""
  },
  "ListOfUsers": {
    "Description": "Comma-separated list of user UPNs",
    "IsRequired": true,
    "DefaultValue": ""
  }
}
#>

$ErrorActionPreference = 'Stop'

$AppGroupName = "$HostPoolName-AppGroup"
$UPNs = $ListOfUsers -replace '\s','' -split ','
$HostPool = Get-AzWvdHostPool | Where-Object name -Match $hostpoolname
$ResourceGroupName = ($HostPool.id -split '/')[4]

function Add-UserToAppGroup {
    Param($UPN,$AppGroupName)
    Write-Output "Creating role assignment"
    $TenantId = $vmConnection.TenantID
    $nerdioApplicationID = $vmConnection.ApplicationID
    $kvSecret = Get-AzKeyVaultSecret -VaultName $KeyVaultName "AzureAD--ClientSecret"
    $ClientSecret = $kvSecret.secretValue
    $nerdioClientSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ClientSecret))
    $AppGroup = Get-AzWvdApplicationGroup -Name $AppGroupName -ResourceGroupName $ResourceGroupName 
    
    $GraphReqTokenBody = @{
        Grant_Type    = "client_credentials"
        Scope         = "https://graph.microsoft.com/.default"
        client_Id     = $nerdioApplicationID
        Client_Secret = $nerdioClientSecret
    } 

    $GraphTokenResponse = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Method POST -Body $GraphReqTokenBody
    if ($GraphTokenResponse.access_token){
        Write-Output "Graph token generated"
    }
    else {
        Write-Error "Failed to generated Graph API token"

    }
    $uri = "https://graph.microsoft.com/v1.0/users/$UPN"
    $UserResults = Invoke-RestMethod -Headers @{Authorization = "Bearer $($GraphTokenResponse.access_token)"} -Uri $uri -Method Get
    $UserId = $UserResults.id 

    Write-Output "UserID is $userID"

    $ReqTokenBody = @{
        Grant_Type    = "client_credentials"
        Scope         = "https://management.azure.com/.default"
        client_Id     = $nerdioApplicationID
        Client_Secret = $nerdioClientSecret
    } 
    $TokenResponse = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Method POST -Body $ReqTokenBody
    if ($TokenResponse.access_token){
        Write-Output "Azure token generated"
    }
    else {
        Write-Error "Failed to generated Azure REST API token"

    }

    $RoleAssignmentId = (new-guid).guid

    $json = @"
{
    "properties": {
        "roleDefinitionId": "$($AppGroup.id)/providers/Microsoft.Authorization/roleDefinitions/1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63",
        "principalId": "$UserId"
    }
}
"@

    $uri = "https://management.azure.com$($AppGroup.id)/providers/Microsoft.Authorization/roleAssignments/$RoleAssignmentId`?api-version=2018-01-01-preview"
    
    Write-Output "Calling PUT $uri"
    Invoke-RestMethod -Headers @{Authorization = "Bearer $($Tokenresponse.access_token)"} -Uri $uri -Method Put -Body $json -ContentType application/json 
}

foreach ($UPN in $UPNs) {
    $SessionHosts = Get-AzWvdSessionHost -HostPoolName $HostPoolName -ResourceGroupName $ResourceGroupName | Where-Object AssignedUser -eq $null
    if ($SessionHosts) {
        $SessionHost = $SessionHosts[0]
        $SessionHostName = ($SessionHost.Name -split '/')[1]
        Add-UserToAppGroup -UPN $upn -AppGroupName $AppGroupName
        Update-AzWvdSessionHost -HostPoolName $HostPoolName -Name $SessionHostName -ResourceGroupName $ResourceGroupName -AssignedUser $upn -ErrorAction Continue
    
        
    }
    else {
        Write-Error "No more hosts available" -ErrorAction Stop
    }
}