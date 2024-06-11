<#
  Author: Akash Chawla
  Source: https://github.com/Azure/RDS-Templates/tree/master/CustomImageTemplateScripts/CustomImageTemplateScripts_2024-03-27
#>

#description: Remove selected AppX Packages
#execution mode: Individual
#tags: Microsoft, Custom Image Template Scripts
<#variables:
{
  "AppxPackages": {
    "Description": "Select built-in AppX packages to remove",
    "DisplayName": "Packages",
    "OptionsSet": [
      {"Value": "Clipchamp.Clipchamp"},
      {"Value": "Microsoft.BingNews"},
      {"Value": "Microsoft.BingWeather"},
      {"Value": "Microsoft.GamingApp"},
      {"Value": "Microsoft.GetHelp"},
      {"Value": "Microsoft.Getstarted"},
      {"Value": "Microsoft.MicrosoftOfficeHub"},
      {"Value": "Microsoft.MicrosoftSolitaireCollection"},
      {"Value": "Microsoft.MicrosoftStickyNotes"},
      {"Value": "Microsoft.MSPaint"},
      {"Value": "Microsoft.Office.OneNote"},
      {"Value": "Microsoft.People"},
      {"Value": "Microsoft.PowerAutomateDesktop"},
      {"Value": "Microsoft.ScreenSketch"},
      {"Value": "Microsoft.SkypeApp"},
      {"Value": "Microsoft.Todos"},
      {"Value": "Microsoft.Windows.Photos"},
      {"Value": "Microsoft.WindowsAlarms"},
      {"Value": "Microsoft.WindowsCalculator"},
      {"Value": "Microsoft.WindowsCamera"},
      {"Value": "Microsoft.windowscommunicationsapps"},
      {"Value": "Microsoft.WindowsFeedbackHub"},
      {"Value": "Microsoft.WindowsMaps"},
      {"Value": "Microsoft.WindowsNotepad"},
      {"Value": "Microsoft.WindowsSoundRecorder"},
      {"Value": "Microsoft.WindowsTerminal"},
      {"Value": "Microsoft.Xbox.TCUI"},
      {"Value": "Microsoft.XboxApp"},
      {"Value": "Microsoft.XboxGameOverlay"},
      {"Value": "Microsoft.XboxGamingOverlay"},
      {"Value": "Microsoft.XboxIdentityProvider"},
      {"Value": "Microsoft.XboxSpeechToTextOverlay"},
      {"Value": "Microsoft.YourPhone"},
      {"Value": "Microsoft.ZuneMusic"},
      {"Value": "Microsoft.ZuneVideo"}
    ]
  }
}
#>

[CmdletBinding()]
  Param (
        [Parameter(
            Mandatory
        )]
        [System.String[]] $AppxPackages
 )

 function Remove-ProvidedAppxPackages($AppxPackages) {
   
        Begin {
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $templateFilePathFolder = "C:\AVDImage"
            Write-host "Starting AVD AIB Customization: Remove Appx Packages : $((Get-Date).ToUniversalTime()) "
        }

        Process {
            Foreach ($App in $AppxPackages) {
                try {                
                    Write-Host "AVD AIB CUSTOMIZER PHASE : Removing Provisioned Package $($App)"
                    Get-AppxProvisionedPackage -Online | Where-Object { $_.PackageName -like ("*{0}*" -f $App) } | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue  | Out-Null
                            
                    Write-Host "AVD AIB CUSTOMIZER PHASE : Attempting to remove [All Users] $App "
                    Get-AppxPackage -AllUsers -Name ("*{0}*" -f $App) | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue 
                            
                    Write-Host "AVD AIB CUSTOMIZER PHASE : Attempting to remove $App"
                    Get-AppxPackage -Name ("*{0}*" -f $App) | Remove-AppxPackage -ErrorAction SilentlyContinue  | Out-Null

                    if($App -eq "Microsoft.MSPaint") {
                        $PaintWindowsName = "Microsoft.Windows.MSPaint"
                        Get-WindowsCapability -Online -Name ("*{0}*" -f $PaintWindowsName) | Remove-WindowsCapability -Online -ErrorAction SilentlyContinue
                    }
                }
                catch {
                    Write-Host "AVD AIB CUSTOMIZER PHASE : Failed to remove Appx Package $App - $($_.Exception.Message)"
                }
            } 
        }
        
        End {

            #Cleanup
            if ((Test-Path -Path $templateFilePathFolder -ErrorAction SilentlyContinue)) {
                Remove-Item -Path $templateFilePathFolder -Force -Recurse -ErrorAction Continue
            }
    
            $stopwatch.Stop()
            $elapsedTime = $stopwatch.Elapsed
            Write-Host "*** AVD AIB CUSTOMIZER PHASE : Remove Appx Packages -  Exit Code: $LASTEXITCODE ***"    
            Write-Host "Ending AVD AIB Customization : Remove Appx Packages - Time taken: $elapsedTime"
        }
 }

 Remove-ProvidedAppxPackages -AppxPackages $AppxPackages