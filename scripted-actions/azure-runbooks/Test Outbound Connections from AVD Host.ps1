#description: Tests network access from AVD hosts to required URLs, including the scripted actions storage account.
#tags: Nerdio, Preview
 
<# Notes:
 
    This script tests network access from AVD hosts to required URLs, including the scripted actions storage account.
    
    Why is this an Azure runbook scripted action instead of a Windows scripted action? 
    Windows scripted actions are downloaded from the scripted actions storage account, 
    so if there is a network access issue to the scripted actions storage account, 
    the Windows scripted action will not be able to run. 
    
    This script runs on the Azure VM directly via Invoke-AzVmRunCommand, 
    so it can test network access to the scripted actions storage account.

    Urls tested include:
    - https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrmXv (AVD Agent download) 
    - https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrxrH (AVD Bootloader download)
    - https://login.microsoftonline.com (Azure AD login)
    - https://catalogartifact.azureedge.net (Azure catalog artifact)
    - https://gcs.prod.monitoring.core.windows.net (Azure monitoring)
    - https://mrsglobalsteus2prod.blob.core.windows.net (Azure MRS global storage)
    - https://wvdportalstorageblob.blob.core.windows.net (Azure WVD portal storage)
    - https://<scripted actions storage account blob endpoint> (the scripted actions storage account)
 
#>
 
function Set-NmeVars {
    param(
        [Parameter(Mandatory=$true)]
        [string]$keyvaultName
    )
    Write-Verbose "Getting Nerdio Manager key vault"
    $script:NmeKeyVault = Get-AzKeyVault -VaultName $keyvaultName
    $script:NmeRg = $NmeKeyVault.ResourceGroupName
}

Set-NmeVars -keyvaultName $KeyVaultName
# get the scripted action storage account
$ScriptedActionsStorageAccount = Get-AzStorageAccount -ResourceGroupName $NmeRg | Where-Object StorageAccountName -Match 'cssa'
if (!$ScriptedActionsStorageAccount) {
    #get the storage account with a tag NMW_OBJECT_TYPE value CUSTOM_SCRIPTS_STORAGE_ACCOUNT
    $ScriptedActionsStorageAccount = Get-AzStorageAccount -ResourceGroupName $NmeRg | Where-Object { $_.Tags.Keys -contains 'NMW_OBJECT_TYPE' } | Where-Object {$_.tags['NMW_OBJECT_TYPE'] -eq 'CUSTOM_SCRIPTS_STORAGE_ACCOUNT'}
}
if (!$ScriptedActionsStorageAccount) {
    Write-Error "Unable to find scripted actions storage account in resource group $NmeRg"
}
# get the blob endpoint for the scripted actions storage account
$ScriptedActionsBlobEndpoint = $ScriptedActionsStorageAccount.PrimaryEndpoints.Blob
# add the blob endpoint to the test URLs
$TestUrls = $ScriptedActionsBlobEndpoint

$Script = @'
param (
    [string[]]$TestUrls,
    [Parameter()]
    [bool]$TestRequiredAvdUrls=$true
)

$TLS12Protocol = [System.Net.SecurityProtocolType] 'Ssl3, Tls12'
[System.Net.ServicePointManager]::SecurityProtocol = $TLS12Protocol
$RequiredAvdUrls =  @(
                        'https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrmXv'
                        'https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrxrH'
                        'https://login.microsoftonline.com'
                        'https://catalogartifact.azureedge.net'
                        'https://gcs.prod.monitoring.core.windows.net'
                        'https://mrsglobalsteus2prod.blob.core.windows.net'
                        'https://wvdportalstorageblob.blob.core.windows.net'
                        )

# Get-WebsiteCertificate function adapted from https://github.com/PoshCode/poshcode.github.io/blob/79c7d2b520927709e87bd6859c8a21a0fa7d7114/scripts/2521.ps1#L97
function Get-WebsiteCertificate {
    
	[CmdletBinding()]
	param (
		[Parameter(Mandatory=$true)] [System.Uri]
			$Uri,
		[Parameter()] [System.IO.FileInfo]
			$OutputFile,
		[Parameter()] [Switch]
			$UseSystemProxy,	
		[Parameter()] [Switch]
			$UseDefaultCredentials,
		[Parameter()] [Switch]
			$TrustAllCertificates
	)
	try {
		$request = [System.Net.WebRequest]::Create($Uri)
		if ($UseSystemProxy) {
			$request.Proxy = [System.Net.WebRequest]::DefaultWebProxy
		}
		
		if ($UseSystemProxy -and $UseDefaultCredentials) {
			$request.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
		}
		
		if ($TrustAllCertificates) {
			# Create a compilation environment
			$Provider=New-Object Microsoft.CSharp.CSharpCodeProvider
			$Compiler=$Provider.CreateCompiler()
			$Params=New-Object System.CodeDom.Compiler.CompilerParameters
			$Params.GenerateExecutable=$False
			$Params.GenerateInMemory=$True
			$Params.IncludeDebugInformation=$False
			$Params.ReferencedAssemblies.Add("System.DLL") > $null
			$TASource=@"
			  namespace Local.ToolkitExtensions.Net.CertificatePolicy {
			    public class TrustAll : System.Net.ICertificatePolicy {
			      public TrustAll() { 
			      }
			      public bool CheckValidationResult(System.Net.ServicePoint sp,
			        System.Security.Cryptography.X509Certificates.X509Certificate cert, 
			        System.Net.WebRequest req, int problem) {
			        return true;
			      }
			    }
			  }
"@ 
			$TAResults=$Provider.CompileAssemblyFromSource($Params,$TASource)
			$TAAssembly=$TAResults.CompiledAssembly

			## We now create an instance of the TrustAll and attach it to the ServicePointManager
			$TrustAll=$TAAssembly.CreateInstance("Local.ToolkitExtensions.Net.CertificatePolicy.TrustAll")
			[System.Net.ServicePointManager]::CertificatePolicy=$TrustAll
		}
		
		try {$response = $request.GetResponse()}
        catch {}
		$servicePoint = $request.ServicePoint
		$certificate = $servicePoint.Certificate
		
		if ($OutputFile) {
			$certBytes = $certificate.Export(
					[System.Security.Cryptography.X509Certificates.X509ContentType]::Cert
				)
			[System.IO.File]::WriteAllBytes( $OutputFile, $certBytes )
			$OutputFile.Refresh()
			return $OutputFile
		} else {
			return $certificate
		}
	} catch {
		Write-Error "Failed to get website certificate. The error was '$_'."
		return $null
	}
	
	<#
		.SYNOPSIS
			Retrieves the certificate used by a website.
	
		.DESCRIPTION
			Retrieves the certificate used by a website. Returns either an object or file.
	
		.PARAMETER  Uri
			The URL of the website. This should start with https.
	
		.PARAMETER  OutputFile
			Specifies what file to save the certificate as.
			
		.PARAMETER  UseSystemProxy
			Whether or not to use the system proxy settings.
			
		.PARAMETER  UseDefaultCredentials
			Whether or not to use the system logon credentials for the proxy.
			
		.PARAMETER  TrustAllCertificates
			Ignore certificate errors for certificates that are expired, have a mismatched common name or are self signed.
	
		.EXAMPLE
			PS C:\> Get-WebsiteCertificate "https://www.gmail.com" -UseSystemProxy -UseDefaultCredentials -TrustAllCertificates -OutputFile C:\gmail.cer
		
		.INPUTS
			Does not accept pipeline input.
	
		.OUTPUTS
			System.Security.Cryptography.X509Certificates.X509Certificate, System.IO.FileInfo
	#>
}


Function Get-RedirectedUrl {

    Param (
        [Parameter(Mandatory=$true)]
        [String]$URL
    )

    try {
        $request = [System.Net.WebRequest]::Create($url)
        $request.AllowAutoRedirect=$false
    
            $response=$request.GetResponse()
        If ($response.StatusCode -match "Found|Moved|Redirect")
        {
            Get-RedirectedUrl $response.GetResponseHeader("Location")
        }
        else {$url}
    }
    catch{$url}

}


# if $TestRequiredAvdUrls is set, add the required AVD URLs to the test urls
if ($TestRequiredAvdUrls) {
    $TestUrls += $RequiredAvdUrls
}
Function Test-Url {
    [CmdletBinding()]
    Param (
        [Parameter(ValueFromPipeline=$true, Mandatory=$true)]
        [string[]]$Urls
    )

    Process {
        foreach ($TestUrl in $Urls) {
            # Ensure the URL starts with http:// or https://
            if ($TestUrl -notmatch '^https?://') {
                $TestUrl = "https://$TestUrl"
            }

            # Get the redirected URL
            $RedirectedUrl = Get-RedirectedUrl $TestUrl


            # Get the certificate for the URL
           $Certificate = Get-WebsiteCertificate $RedirectedUrl -erroraction SilentlyContinue
            # Parse the URL to get the domain name
            $DomainName = $RedirectedUrl -replace 'https?://([^/]+).*', '$1'

            # Perform DNS resolution
            $DnsResolution = Resolve-DnsName -Name $DomainName -Type A -erroraction SilentlyContinue

            #$NetConnection = Test-NetConnection -ComputerName $DomainName -Port 443 -InformationLevel Quiet -ErrorAction SilentlyContinue

            # Output the results
            [PSCustomObject]@{
                OriginalUrl    = $TestUrl
                RedirectedUrl  = $RedirectedUrl
                Certificate    = $Certificate
                DnsResolution  = $DnsResolution.IPAddress 
            }
        }
    }
}

# Main script execution
if ($TestUrls) {
    #Write-Output "Testing URLs: $($TestUrls -join ', ')"
    $Results = $TestUrls | Test-Url

    # Output the results
    $output = foreach ($Result in $Results) {
        Write-Output "URL: $($Result.OriginalUrl)"
        if ($Result.RedirectedUrl -ne $result.OriginalUrl) {Write-Output "Redirected URL: $($Result.RedirectedUrl)"}
        Write-Output "Certificate Subject: $($Result.Certificate.Subject)"
        Write-Output "Certificate Issuer: $($Result.Certificate.Issuer)"
        Write-Output "DNS Resolution: $($Result.DnsResolution | Out-String)"
    }
    # truncate output to first 4kb
    if ($output.Length -gt 4096) {
        $output = $output.Substring(0, 4096)
    }
    Write-Output $output
} else {
    Write-Output "No URLs provided for testing."
}
'@

$Script | Out-File ".\Test-AvdNetworkAccess.ps1"

# Execute local script on remote VM
Write-Output "Execute network access test script on remote VM"
$RunCommand = Invoke-AzVMRunCommand -ResourceGroupName $AzureResourceGroupName -VMName "$AzureVMName" -CommandId 'RunPowerShellScript' -ScriptPath ".\Test-AvdNetworkAccess.ps1" -Parameter @{"TestUrls"=$TestUrls}

Write-output "Output from RunCommand:"
($RunCommand.Value | ? Code -eq 'ComponentStatus/StdOut/succeeded').Message
$errors = $RunCommand.Value | ? Code -eq 'ComponentStatus/StdErr/succeeded'
if ($errors.message) {
    Write-output "Error running script on $VMName. $($errors.message)"
}