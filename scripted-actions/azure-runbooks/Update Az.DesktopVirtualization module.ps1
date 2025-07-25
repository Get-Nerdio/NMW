#description: Update AZ.DesktopVirtualization to the latest version.
#tags: Nerdio, Preview

<#
Notes:
This Scripted Action will update the AZ.DesktopVirtualization module to the latest version for selected Automation Account. 
#>

<# Variables:
{
  "AutomationAccountName": {
    "Description": "Name of Automation Account.",
    "IsRequired": true,
    "DefaultValue": ""
  },
  "AutomationAccountResourceGroup": {
    "Description": "Resource Group of Automation Account.",
    "IsRequired": true,
    "DefaultValue": ""
  }
}
#>

$PsGalleryApiUrl = 'https://www.powershellgallery.com/api/v2'
$ModuleToUpdate = 'AZ.DesktopVirtualization'

function Install-AutomationModule {
    param (
       [string] $ModuleName
    )
    Write-Output "Update module: $ModuleName"
    $ModuleContentFormat = "$PsGalleryApiUrl/package/{0}"
    $ModuleContentUrl  = $ModuleContentFormat -f $ModuleName

    New-AzAutomationModule -ResourceGroupName $AutomationAccountResourceGroup `
    -AutomationAccountName $AutomationAccountName `
    -Name $ModuleName `
    -ContentLink $ModuleContentUrl > $null
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ModuleUrlFormat = "$PsGalleryApiUrl/Search()?`$filter={1}&searchTerm=%27{0}%27&targetFramework=%27%27&includePrerelease=false&`$skip=0&`$top=40"
$ModuleUrl = $ModuleUrlFormat -f $ModuleToUpdate, 'IsLatestVersion'

$SearchResult = Invoke-RestMethod -Method Get -Uri $ModuleUrl -UseBasicParsing

if ($SearchResult.Length -and $SearchResult.Length -gt 1) {
    $SearchResult = $SearchResult | Where-Object { $_.title.InnerText -eq $ModuleToUpdate }
}

$PackageDetails = Invoke-RestMethod -Method Get -UseBasicParsing -Uri $SearchResult.id
$Dependencies = $PackageDetails.entry.properties.dependencies
$RequiredModules = $Dependencies.Split("|")

foreach ($RequiredModule in $RequiredModules) {
    $RequiredModuleName = ($RequiredModule.Split(":"))[0]
    Install-AutomationModule $RequiredModuleName
}

Install-AutomationModule $ModuleToUpdate