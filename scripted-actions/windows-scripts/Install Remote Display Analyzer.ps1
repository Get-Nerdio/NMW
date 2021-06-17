#description: Installs the latest version of Remote Display Analyzer (RDAnalyzer) and places it on all users' desktop
#execution mode: Combined
#tags: Nerdio, Apps install
<#
This script downloads and installs the latest version of Remote Display Analyzer (RDAnalyzer) and places it on all users' desktop (C:\Users\Public\Desktop).

Visit https://rdanalyzer.com/ for more information.
#>

Function Get-GitHubRelease {
    <#
    .SYNOPSIS
    Downloads a release from a GitHub repository
    
    .DESCRIPTION
    Downloads the latest or specific release from a specific GitHub repository using the API
    
    .PARAMETER Repository
    The main repository that needs to be downloaded
    
    .PARAMETER DownloadPath
    Location of the download
    
    .PARAMETER Version
    Specific version, by default latest
    
    .EXAMPLE
    Get-GitHubRelease -Repository "RDAnalyzer/release" -DownloadPath "c:\Users\Public\Desktop"
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]
        $Repository,

        [Parameter(Mandatory = $true)]
        [string]
        $DownloadPath,

        [Parameter(Mandatory = $false )]
        [string]
        $Version = "Latest"
    )

    $uri = "https://api.github.com/repos/$($Repository)/releases"

    try {
        $releases = Invoke-RestMethod -Method GET -Uri $uri -ContentType "application/json"
    } catch {
        throw "Something went wrong while contacting: $($uri). $($_.Exception.Message)"
    }

    if ($Version -eq "latest") {
        $select = $releases[0]
    } else {
        $select = $releases | Where-Object {$_.Name -like "*$($Version)*"}

        if (!($select)) {
            throw "Cannot find version $($Version)."
        } elseif ($select.Count -gt 1) {
            throw "Muliple versions found, please specify a specific version."
        }
    }

    $windowsDownload = ($select.assets | Where-Object {$_.Name -like "*RemoteDisplayAnalyzer.exe"})
    $downloadUri = $windowsDownload.browser_download_url
    $downloadName = $windowsDownload.name

    try {
        if (!(Test-Path -Path $DownloadPath)) {
            New-Item -Path $DownloadPath -ItemType Directory -Force | Out-Null
        }

        Invoke-WebRequest -Uri $downloadUri -OutFile "$($DownloadPath)\$($downloadName)" | Out-Null
    } catch {
        throw "Issue while downloading file: $($downloadUri) to path $($DownloadPath). $($_.Exception.Message)"
    }

    return [PSCustomObject]@{
        Version = $select.name
        Download = "$($DownloadPath)\$($downloadName)"
    } 
}

$rdaDownload = Get-GitHubRelease -Repository "RDAnalyzer/release" -DownloadPath "C:\Users\Public\Desktop"

Write-Host "Downloaded Remote Display Analyzer version $($rdaDownload.Version) to path $($rdaDownload.Download)"
