<#
.SYNOPSIS
    Uninstalls Crowdstrike with Uninstall Token
.DESCRIPTION
	Pre Reqs:
	- Crowdstrike API Key with the following permissions:
		- Hosts (Read + Write)
			- Read: for viewing hostid key
			- Write: for POSTing Host ID to API to remove device from CS console.
		- Sensor update policies (Read + Write) 
			- Read: for viewing Uninstall Token.
			- Write: for POSTing computername to API, which returns CS HostID
	- Secure variables defined in Nerdio
	  - CsUninstallTool - The URI to a CsUninstallTool.exe file. Ensure this path is accessible to the host VM.
	  - CsApiClientId - API Client ID from CrowdStrike.
	  - CsApiClientSecret - API Client Secret from CrowdStrike.
	
	Overview:
	Defines 4 functions:
	  - Get-CrowdstrikeToken
	  - Get-CrowdstrikeHostId
	  - Get-CrowdstrikeUninstallToken
	  - Remove-CrowdstrikeDevice
	
	Downloads CsUninstallTool.exe from SRpublic storage acct.
	Utilizes 2 Nerdio Secure Variables, one for API CsApiClientid, one for client_secret.
	Gets a Crowdstrike API token with these two variables.
	Gets the Crowdstrike Host ID for the host running the script.
	Gets the uninstall token for the host running the script.
	Runs the CSUninstallTool.exe on the AVD host running the script with the maintenancetoken flag.
	Utilizes the CS API to remove the device from the Crowdstrike Console.

.NOTES
	Company:  Steel Root, Inc.
	Author:   Tom Biscardi
	Website:  steelroot.us
	Created:  2022-02-17
#>

#Function Definition:
function Get-CrowdstrikeToken {
	<#
	.SYNOPSIS
		Returns a Crowdstrike Token
	.DESCRIPTION
		Gets a Crowdstrike Token from a client_id, client_secret
	.EXAMPLE
		
	.INPUTS
		
	.OUTPUTS
		$global:CrowdstrikeToken
		API Token Object
	.NOTES
		API Endpoint: /oauth2/token
	#>

	[CmdletBinding()]
	param (
		
		# Client ID
		[Parameter(Mandatory=$true)]
		[string] $ClientId,

		# Client Secret
		[Parameter(Mandatory=$true)]
		[string] $ClientSecret,

		# Env
		[Parameter(Mandatory=$true)]
		[ValidateSet("Regular","Gov")]
		[string] $Env

	)

	#If gov, use gov api:
	if ($Env -eq "Gov"){
		$baseapiuri = "https://api.laggar.gcw.crowdstrike.com"
	}
	#If not gov, use regular api:
	else{
		$baseapiuri = "https://api.crowdstrike.com"
	}

	#Build the URI for the Oauth2 Token Endpoint:
	$uri = $baseapiuri + "/oauth2/token"

	#Build the splatted paramaters for Invoke-WebRequest
	$param = @{
		Uri = "$uri"
		method = 'post'
		headers = @{
			accept = 'application/json'
			'content-type' = 'application/x-www-form-urlencoded'
		}
		body = 'client_id='+$clientid+'&client_secret='+$clientsecret
	}	

	#Verbosity
	Write-Verbose "Writing to $uri`:`n`n $body"

	#Call the API 
	$token = Invoke-RestMethod @param

	#Set a global varialble for the token (helps with troubleshooting, but not used)
	$global:CrowdstrikeToken = $token

	#returns the object returned by the API
	return $token
}

function Get-CrowdstrikeHostId {
	<#
	.SYNOPSIS
		Gets the crowdstrike host id from the hostname
	.DESCRIPTION
	.EXAMPLE
	.INPUTS
	.OUTPUTS
	.NOTES
		Required scopes: hosts (Read)
		API Endpoint: /devices/queries/devices/v1
	#>

	[CmdletBinding()]
	param (
		# Hostname
		[Parameter(Mandatory=$true)]
		[string] $Hostname,

		# Token
		[Parameter(Mandatory=$true)]
		$CrowdstrikeToken,

		# Env
		[Parameter(Mandatory=$true)]
		[ValidateSet("Regular","Gov")]
		[string] $Env
		
	)

	if ($Env -eq "Gov"){
		$baseapiuri = "https://api.laggar.gcw.crowdstrike.com"
	}
	#If not gov, use commercial api:
	else{
		$baseapiuri = "https://api.crowdstrike.com"
	}

	#Build the URI for the Oauth2 Token Endpoint:
	$uri = $baseapiuri + "/devices/queries/devices/v1?filter=hostname:'" + $hostname+ "'"

	#Build the splatted paramaters for Invoke-WebRequest
	$param = @{
		Uri = "$uri"
		method = 'get'
		headers = @{
			accept = 'application/json'
			'authorization' = "bearer $($CrowdstrikeToken.access_token)"
		}
	}	

	#Verbosity
	Write-Verbose "GET from $uri`:`n`n"
	
	#Call the API 
	$CrowdstrikeHostId = Invoke-RestMethod @param

	#Set a global varialble for the hostid (helps with troubleshooting, but not used)
	$global:crowdstrikeHostId = $CrowdstrikeHostId

	#returns the "resources" object from the API response.
	return $CrowdstrikeHostId.resources[0]
}

function Get-CrowdstrikeUninstallToken {
	<#
	.SYNOPSIS
		Get-CrowdstrikeUninstallToken
	.DESCRIPTION
		Utilizes the Crowdstrike API to get a crowdstrike uninstall token
	.EXAMPLE
	.INPUTS
	.OUTPUTS
	.NOTES
		API Endpoint: /policy/combined/reveal-uninstall-token/v1
		API Permissions: Sensor Update Policies (Read & Write) 
	#>

	[CmdletBinding()]
	param (
		# HostID
		[Parameter(Mandatory=$true)]
		[string] $HostID,
		
		# Token
		[Parameter(Mandatory=$true)]
		$CrowdstrikeToken,

		# Env
		[Parameter(Mandatory=$true)]
		[ValidateSet("Regular","Gov")]
		[string] $Env
	)


	if ($Env -eq "Gov"){
		$baseapiuri = "https://api.laggar.gcw.crowdstrike.com"
	}
	#If not gov, use commercial api:
	else{
		$baseapiuri = "https://api.crowdstrike.com"
	}

	#Build the URI for the Oauth2 Token Endpoint:
	$uri = $baseapiuri + "/policy/combined/reveal-uninstall-token/v1"

	#Create the body of the API request
	$body = @{
		audit_message = "AVD Uninstall Script"
		device_id = $HostID
	  }
	
	#Convert the hashtable to JSON
	$body = $body | ConvertTo-Json

	#Build the splatted paramaters for Invoke-WebRequest
	$param = @{
		Uri = "$uri"
		method = 'post'
		headers = @{
			accept = 'application/json'
			'authorization' = "bearer $($CrowdstrikeToken.access_token)"
			'content-type' = 'application/json'
		}
		body = $body
	}	

	Write-Verbose "Writing to $uri`:`n`n $body"

	#Call the API 
	$CrowdstrikeUninstallKey = Invoke-RestMethod @param

	$global:crowdstrikeUninstallKey = $CrowdstrikeUninstallKey

	return $CrowdstrikeUninstallKey.resources.uninstall_token
}

function Remove-CrowdstrikeDevice {
	<#
	.SYNOPSIS
		Remove-CrowdstrikeDevice
	.DESCRIPTION
		Utilizes the Crowdstrike API to remove a crowdstrike device
	.EXAMPLE

	.INPUTS

	.OUTPUTS

	.NOTES
		Required scopes: hosts (Read & Write)
		API Endpoint: /devices/queries/devices/v1
	#>

	[CmdletBinding()]
	param (
		# HostID
		[Parameter(Mandatory=$true)]
		[string] $HostID,
		
		# Token
		[Parameter(Mandatory=$true)]
		$CrowdstrikeToken,

		# Env
		[Parameter(Mandatory=$true)]
		[ValidateSet("Regular","Gov")]
		[string] $Env
	)


	if ($Env -eq "Gov"){
		$baseapiuri = "https://api.laggar.gcw.crowdstrike.com"
	}
	#If not gov, use commercial api:
	else{
		$baseapiuri = "https://api.crowdstrike.com"
	}

	#Build the URI for the Oauth2 Token Endpoint:
	$uri = $baseapiuri + "/devices/entities/devices-actions/v2?action_name=hide_host&ids=$HostId"

	#Construct the body
	$body = @{
		action_parameters = [array]@{
			name = "action_name"
			value = "hide_host"
		}
		ids = [array]$HostID
	  }
	
	$body = $body | ConvertTo-Json


	#Build the splatted paramaters for Invoke-WebRequest
	$param = @{
		Uri = "$uri"
		method = 'post'
		headers = @{
			accept = 'application/json'
			'authorization' = "bearer $($CrowdstrikeToken.access_token)"
			'content-type' = 'application/json'
		}
		body = $body
	}	

	Write-Verbose "Writing to $uri`:`n`n $body"

	#Call the API 
	$CrowdstrikeRemoval = Invoke-RestMethod @param

	$global:crowdstrikeRemoval = $CrowdstrikeRemoval

	return $CrowdstrikeRemoval
}


#Variable Definition:
#Link to .exe on Public Storage
$PublicUrl = $SecureVars.CsUninstallTool

#Local directory to keep the installer
$LocalDirectory = 'C:\Temp\'

<# #Secure Variables from Nerdio, noted here for extra clarity:
	$SecureVars.CsApiClientId is The CrowdStrike API Client ID 
	$SecureVars.CsApiClientSecret is The CrowdStrike API Client Secret
#>

#Local Directory + the filename obtained from the URL 
#Sorry this is stupid long, but it's looking at how many things are returned when you split"/",
#then grabbing the very last one of them, aka the filename + extenson
$LocalFile ="$LocalDirectory"+ ($PublicUrl.split("/") | Select-Object -Last 1)

# Create a TEMP directory if one does not already exist
if (!(Test-Path -Path '$LocalDirectory' -ErrorAction SilentlyContinue)) {
    #Creates the directory
    New-Item -ItemType Directory -Path $LocalDirectory -Force -Verbose
}

#Download Sensor from the SRPublic Share to the Local Directory
Invoke-WebRequest -Uri $PublicUrl -OutFile $LocalFile -Verbose

#Get Crowdstrike API Token from API Client ID & Client Secret (Defined as nerdio variables)
$CsToken = Get-CrowdstrikeToken `
	-ClientId $SecureVars.CsApiClientId `
	-ClientSecret $SecureVars.CsApiClientSecret `
	-Env Gov `
	-Verbose

#Check to see if we obtained an API Bearer Token.
If ($null -eq $CsToken.access_token){
	Write-Error "Failed to obtain token"
}

#Verbosity:
Write-Output "Token: $($cstoken.access_token)"

#Get Crowdstrike Host ID for the host running the script from CrowdStrike API
$CsHostId = Get-CrowdstrikeHostId `
	-Hostname $env:COMPUTERNAME `
	-CrowdstrikeToken $CsToken `
	-Env Gov `
	-Verbose

#Check to see if we obtained a Host ID from the CS API
if ($null -eq $CsHostId){
	Write-Error "Failed to obtain Host ID for this host: $env:computername."
}

#Verbosity:
Write-Output "Host ID: $CsHostId"

#Get Crowdstrike Uninstall Token from the provided CrowdStrike HostID 
#(Note: if multiple hosts are returned, this gets the first one)
$CsUninstallKey = Get-CrowdstrikeUninstallToken `
	-HostID $CsHostId `
	-CrowdstrikeToken $CsToken `
	-Env Gov `
	-Verbose

#Check to see if we obtained an Uninstall Token from the CS API
if ($null -eq $CsUninstallKey){
	Write-Error "Failed to obtain Uninstall Key for this host: $env:computername."
}

#Verbosity
Write-Verbose "Running: $LocalFile"
Write-Verbose "Using Maintenance Token: $CsUninstallKey"

#Run the Uninstall Tool w/ the token we just generated
& $LocalFile MAINTENANCE_TOKEN=$CsUninstallKey /quiet

#Remove the host from Crowdstrike's console
#Technically, this should remove the device from the Crowdstrike Console regardless of if the uninstall works.
$CsRemoval = Remove-CrowdstrikeDevice `
	-HostID $CsHostId `
	-CrowdstrikeToken $Cstoken `
	-Env Gov `
	-Verbose

#Check Removal Status
if ($null -eq $CsRemoval.resources){
	Write-Error "Failed to remove $env:computername from Crowdstrike Console."
}

#Verbosity
Write-Output "$csremoval"

#Remove Installer
Remove-Item -Path $LocalFile -Verbose

#Remove Directory (if it's empty)
if ((Get-ChildItem -Path $LocalDirectory).count -eq 0){
    #Directory Is Empty
    Remove-Item -Path $LocalDirectory -Verbose
}
