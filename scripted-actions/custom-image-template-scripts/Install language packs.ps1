<#
  Author: Akash Chawla
  Source: https://github.com/Azure/RDS-Templates/blob/master/CustomImageTemplateScripts/CustomImageTemplateScripts_2023-06-12
#>

#description: Install language packs
#execution mode: Individual
#tags: Microsoft, Custom Image Template Scripts
<#variables:
{
  "LanguageList": {
    "Description": "Select any additional languages to be added",
    "DisplayName": "Languages"
  }
}
#>

[CmdletBinding()]
  Param (
        [Parameter(
            Mandatory
        )]
        [ValidateSet("Arabic (Saudi Arabia)","Bulgarian (Bulgaria)","Chinese (Simplified, China)","Chinese (Traditional, Taiwan)","Croatian (Croatia)","Czech (Czech Republic)","Danish (Denmark)","Dutch (Netherlands)", "English (United Kingdom)", "Estonian (Estonia)", "Finnish (Finland)", "French (Canada)", "French (France)", "German (Germany)", "Greek (Greece)", "Hebrew (Israel)", "Hungarian (Hungary)", "Italian (Italy)", "Japanese (Japan)", "Korean (Korea)", "Latvian (Latvia)", "Lithuanian (Lithuania)", "Norwegian, Bokmål (Norway)", "Polish (Poland)", "Portuguese (Brazil)", "Portuguese (Portugal)", "Romanian (Romania)", "Russian (Russia)", "Serbian (Latin, Serbia)", "Slovak (Slovakia)", "Slovenian (Slovenia)", "Spanish (Mexico)", "Spanish (Spain)", "Swedish (Sweden)", "Thai (Thailand)", "Turkish (Turkey)", "Ukrainian (Ukraine)", "English (Australia)", "English (United States)")]
        [System.String[]]$LanguageList
    )

function Install-LanguagePack {
  
   
    <#
    Function to install language packs along with features on demand: 
    https://learn.microsoft.com/en-gb/powershell/module/languagepackmanagement/install-language?view=windowsserver2022-ps
    #>

    BEGIN {
        
        $templateFilePathFolder = "C:\AVDImage"
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Write-host "Starting AVD AIB Customization: Install Language packs: $((Get-Date).ToUniversalTime()) "

         # populate dictionary
         $LanguagesDictionary = @{}
         $LanguagesDictionary.Add("Arabic (Saudi Arabia)", "ar-SA")
         $LanguagesDictionary.Add("Bulgarian (Bulgaria)", "bg-BG")
         $LanguagesDictionary.Add("Chinese (Simplified, China)", "zh-CN")
         $LanguagesDictionary.Add("Chinese (Traditional, Taiwan)", "zh-TW")
         $LanguagesDictionary.Add("Croatian (Croatia)",	"hr-HR")
         $LanguagesDictionary.Add("Czech (Czech Republic)",	"cs-CZ")
         $LanguagesDictionary.Add("Danish (Denmark)",	"da-DK")
         $LanguagesDictionary.Add("Dutch (Netherlands)",	"nl-NL")
         $LanguagesDictionary.Add("English (United States)",	"en-US")
         $LanguagesDictionary.Add("English (United Kingdom)",	"en-GB")
         $LanguagesDictionary.Add("Estonian (Estonia)",	"et-EE")
         $LanguagesDictionary.Add("Finnish (Finland)",	"fi-FI")
         $LanguagesDictionary.Add("French (Canada)",	"fr-CA")
         $LanguagesDictionary.Add("French (France)",	"fr-FR")
         $LanguagesDictionary.Add("German (Germany)",	"de-DE")
         $LanguagesDictionary.Add("Greek (Greece)",	"el-GR")
         $LanguagesDictionary.Add("Hebrew (Israel)",	"he-IL")
         $LanguagesDictionary.Add("Hungarian (Hungary)",	"hu-HU")
         $LanguagesDictionary.Add("Indonesian (Indonesia)",	"id-ID")
         $LanguagesDictionary.Add("Italian (Italy)",	"it-IT")
         $LanguagesDictionary.Add("Japanese (Japan)",	"ja-JP")
         $LanguagesDictionary.Add("Korean (Korea)",	"ko-KR")
         $LanguagesDictionary.Add("Latvian (Latvia)",	"lv-LV")
         $LanguagesDictionary.Add("Lithuanian (Lithuania)",	"lt-LT")
         $LanguagesDictionary.Add("Norwegian, Bokmål (Norway)",	"nb-NO")
         $LanguagesDictionary.Add("Polish (Poland)",	"pl-PL")
         $LanguagesDictionary.Add("Portuguese (Brazil)",	"pt-BR")
         $LanguagesDictionary.Add("Portuguese (Portugal)",	"pt-PT")
         $LanguagesDictionary.Add("Romanian (Romania)",	"ro-RO")
         $LanguagesDictionary.Add("Russian (Russia)",	"ru-RU")
         $LanguagesDictionary.Add("Serbian (Latin, Serbia)",	"sr-Latn-RS")
         $LanguagesDictionary.Add("Slovak (Slovakia)",	"sk-SK")
         $LanguagesDictionary.Add("Slovenian (Slovenia)",	"sl-SI")
         $LanguagesDictionary.Add("Spanish (Mexico)",	"es-MX")
         $LanguagesDictionary.Add("Spanish (Spain)",	"es-ES")
         $LanguagesDictionary.Add("Swedish (Sweden)",	"sv-SE")
         $LanguagesDictionary.Add("Thai (Thailand)",	"th-TH")
         $LanguagesDictionary.Add("Turkish (Turkey)",	"tr-TR")
         $LanguagesDictionary.Add("Ukrainian (Ukraine)",	"uk-UA")
         $LanguagesDictionary.Add("English (Australia)",	"en-AU")
    } # Begin
    PROCESS {

        foreach ($Language in $LanguageList) {

            # retry in case we hit transient errors
            for($i=1; $i -le 5; $i++) {
                 try {
                    Write-Host "*** AVD AIB CUSTOMIZER PHASE : Install language packs -  Attempt: $i ***"   
                    $LanguageCode =  $LanguagesDictionary.$Language
                    Install-Language -Language $LanguageCode
                    Write-Host "*** AVD AIB CUSTOMIZER PHASE : Install language packs -  Installed language $LanguageCode ***"   
                    break
                }
                catch {
                        Write-Host "*** AVD AIB CUSTOMIZER PHASE : Install language packs - Exception occurred***"
                        Write-Host $PSItem.Exception
                        continue
                }
            }
        }
    } #Process
    END {

        #Cleanup
        if ((Test-Path -Path $templateFilePathFolder -ErrorAction SilentlyContinue)) {
            Remove-Item -Path $templateFilePathFolder -Force -Recurse -ErrorAction Continue
        }

        $stopwatch.Stop()
        $elapsedTime = $stopwatch.Elapsed
        Write-Host "*** AVD AIB CUSTOMIZER PHASE : Install language packs -  Exit Code: $LASTEXITCODE ***"    
        Write-Host "Ending AVD AIB Customization : Install language packs - Time taken: $elapsedTime"
    } 
}

 Install-LanguagePack -LanguageList $LanguageList