#description: Install the NinjaRMM agent.
#execution mode: Individual
#tags: Nerdio, NinjaRMM

<#
Notes:
The installation script requires an NinjaRMM agent download URL.
You must provide secure variables to this script as seen in the Required Variables section. 
Set these up in Nerdio Manager under Settings->Portal. The variables to create are:
    NinjaDownloadURL
#>

##### Required Variables #####

$NinjaDownloadURL = $SecureVars.NinjaDownloadURL

##### Script Logic #####

if($NinjaDownloadURL -eq $null) {
    Write-Output "ERROR: The secure variable NinjaDownloadURL are not provided"
}

else {    
    $InstallerName = $NinjaDownloadURL.Split("/") | Select-Object -Last 1
    $InstallerPath = Join-Path $Env:TMP $InstallerName

    [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072)
    $WebClient = New-Object System.Net.WebClient
    $WebClient.DownloadFile($NinjaDownloadURL, $InstallerPath)


    Start-Process $InstallerPath
} 