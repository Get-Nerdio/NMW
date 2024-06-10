<#
  Author: Akash Chawla
  Source: https://github.com/Azure/RDS-Templates/tree/master/CustomImageTemplateScripts/CustomImageTemplateScripts_2023-09-15
#>

#description: Configure Microsoft Teams optimizations
#execution mode: Individual
#tags: Microsoft, Custom Image Template Scripts
<#variables:
{
  "TeamsDownloadLink": {
    "Description": "Select Microsoft Teams client version",
    "DisplayName": "Teams client",
    "OptionsSet": [
      {"Label": "Latest", "Value": "https://teams.microsoft.com/downloads/desktopurl?env=production&plat=windows&arch=x64&managedInstaller=true&download=true"},
      {"Label": "Latest (x32)", "Value": "https://teams.microsoft.com/downloads/desktopurl?env=production&plat=windows&managedInstaller=true&download=true"},
      {"Label": "1.6.00.4472", "Value": "https://statics.teams.cdn.office.net/production-windows-x64/1.6.00.4472/Teams_windows_x64.msi"},
      {"Label": "1.6.00.1381", "Value": "https://statics.teams.cdn.office.net/production-windows-x64/1.6.00.1381/Teams_windows_x64.msi"},
      {"Label": "1.6.00.376", "Value": "https://statics.teams.cdn.office.net/production-windows-x64/1.6.00.376/Teams_windows_x64.msi"},
      {"Label": "1.5.00.36367", "Value": "https://statics.teams.cdn.office.net/production-windows-x64/1.5.00.36367/Teams_windows_x64.msi"},
      {"Label": "1.5.00.31168", "Value": "https://statics.teams.cdn.office.net/production-windows-x64/1.5.00.31168/Teams_windows_x64.msi"}
    ]
  },
  "WebRTCInstaller": {
    "Description": "Select WebRTC version",
    "DisplayName": "WebRTC",
    "OptionsSet": [
      {"Label": "1.33.2302.07001", "Value": "https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWWDIg"},
      {"Label": "1.31.2211.15001", "Value": "https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RE5c8Kk"},
      {"Label": "1.17.2205.23001", "Value": "https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RE4YM8L"},
      {"Label": "1.4.2111.18001", "Value": "https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWQ1UW"}
    ]
  },
  "VCRedistributableLink": {
    "Description": "Select Visual C++ Redistributable version",
    "DisplayName": "Visual C++ Redistributable",
    "OptionsSet": [
      {"Label": "x86", "Value": "https://aka.ms/vs/17/release/vc_redist.x86.exe"},
      {"Label": "x64", "Value": "https://aka.ms/vs/17/release/vc_redist.x64.exe"}
    ]
  }
}
#>

# Reference: https://learn.microsoft.com/en-us/azure/virtual-desktop/teams-on-avd

[CmdletBinding()]
  Param (
        [Parameter(Mandatory)]
        [string]$TeamsDownloadLink,

        [Parameter(
            Mandatory
        )]
        [string]$VCRedistributableLink,

        [Parameter(
            Mandatory
        )]
        [string]$WebRTCInstaller
)
 
 function InstallTeamsOptimizationforAVD($TeamsDownloadLink, $VCRedistributableLink, $WebRTCInstaller) {
   
        Begin {
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $templateFilePathFolder = "C:\AVDImage"
            Write-host "Starting AVD AIB Customization: Teams Optimization : $((Get-Date).ToUniversalTime()) "
        }

        Process {
            
            try {     
                # Set reg key
                New-Item -Path HKLM:\SOFTWARE\Microsoft -Name "Teams" 
                $registryPath = "HKLM:\SOFTWARE\Microsoft\Teams"
                $registryKey = "IsWVDEnvironment"
                $registryValue = "1"
                Set-RegKey -registryPath $registryPath -registryKey $registryKey -registryValue $registryValue 
                
                # Install the latest version of the Microsoft Visual C++ Redistributable
                Write-host "AVD AIB Customization: Teams Optimization - Starting the installation of latest Microsoft Visual C++ Redistributable"
                $appName = 'teams'
                $drive = 'C:\'
                New-Item -Path $drive -Name $appName  -ItemType Directory -ErrorAction SilentlyContinue
                $LocalPath = $drive + '\' + $appName 
                Set-Location $LocalPath
                $VCRedistExe = 'vc_redist.x64.exe'
                $outputPath = $LocalPath + '\' + $VCRedistExe
                Invoke-WebRequest -Uri $VCRedistributableLink -OutFile $outputPath
                Start-Process -FilePath $outputPath -Args "/install /quiet /norestart /log vcdist.log" -Wait
                Write-host "AVD AIB Customization: Teams Optimization - Finished the installation of latest Microsoft Visual C++ Redistributable"

                # Install the Remote Desktop WebRTC Redirector Service
                $webRTCMSI = 'webSocketSvc.msi'
                $outputPath = $LocalPath + '\' + $webRTCMSI
                Invoke-WebRequest -Uri $WebRTCInstaller -OutFile $outputPath
                Start-Process -FilePath msiexec.exe -Args "/I $outputPath /quiet /norestart /log webSocket.log" -Wait
                Write-host "AVD AIB Customization: Teams Optimization - Finished the installation of the Teams WebSocket Service"

                #Install Teams
                $teamsMsi = 'teams.msi'
                $outputPath = $LocalPath + '\' + $teamsMsi
                Invoke-WebRequest -Uri $TeamsDownloadLink -OutFile $outputPath
                Start-Process -FilePath msiexec.exe -Args "/I $outputPath /quiet /norestart /log teams.log ALLUSER=1 ALLUSERS=1" -Wait
                Write-host "AVD AIB Customization: Teams Optimization - Finished installation of Teams"
            }
            catch {
                Write-Host "*** AVD AIB CUSTOMIZER PHASE ***  Teams Optimization  - Exception occured  *** : [$($_.Exception.Message)]"
            }    
        }
        
        End {

            #Cleanup
            if ((Test-Path -Path $templateFilePathFolder -ErrorAction SilentlyContinue)) {
                Remove-Item -Path $templateFilePathFolder -Force -Recurse -ErrorAction Continue
            }
    
            $stopwatch.Stop()
            $elapsedTime = $stopwatch.Elapsed
            Write-Host "*** AVD AIB CUSTOMIZER PHASE : Teams Optimization -  Exit Code: $LASTEXITCODE ***"    
            Write-Host "Ending AVD AIB Customization : Teams Optimization - Time taken: $elapsedTime"
        }
 }

function Set-RegKey($registryPath, $registryKey, $registryValue) {
    try {
         Write-Host "*** AVD AIB CUSTOMIZER PHASE ***  Teams Optimization  - Setting  $registryKey with value $registryValue ***"
         New-ItemProperty -Path $registryPath -Name $registryKey -Value $registryValue -PropertyType DWORD -Force -ErrorAction Stop
    }
    catch {
         Write-Host "*** AVD AIB CUSTOMIZER PHASE ***  Teams Optimization  - Cannot add the registry key  $registryKey *** : [$($_.Exception.Message)]"
    }
 }

InstallTeamsOptimizationforAVD -TeamsDownloadLink $TeamsDownloadLink -VCRedistributableLink $VCRedistributableLink -WebRTCInstaller $WebRTCInstaller
