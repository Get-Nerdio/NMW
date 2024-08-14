<#
  Author: Akash Chawla
  Source: https://github.com/Azure/RDS-Templates/tree/master/CustomImageTemplateScripts/CustomImageTemplateScripts_2024-03-27
#>

#description: Install FSLogix. This also configures MS Defender anti-virus exclusions
#execution mode: Individual
#tags: Microsoft, Custom Image Template Scripts
<#variables:
{
  "ProfilePath": {
    "Description": "Enter the SMB path for your FSLogix profiles",
    "DisplayName": "Profile path"
  },
  "VHDSize": {
    "Description": "Specify the size for new VHD(x) in megabytes",
    "DisplayName": "VHD size (MB)",
    "Type": "uint"
  }
}
#>

Param (        
    [Parameter(Mandatory=$false)]
        [string]$ProfilePath,

    [Parameter(Mandatory=$false)]
        [string]$VHDSize
)

######################
#    WVD Variables   #
######################
$LocalWVDpath            = "c:\temp\wvd\"
$FSInstaller             = 'FSLogixAppsSetup.zip'
$templateFilePathFolder = "C:\AVDImage"

####################################
#    Test/Create Temp Directory    #
####################################
if((Test-Path c:\temp) -eq $false) {
    Write-Host "AVD AIB Customization - Install FSLogix : Creating temp directory"
    New-Item -Path c:\temp -ItemType Directory
}
else {
    Write-Host "AVD AIB Customization - Install FSLogix : C:\temp already exists"
}
if((Test-Path $LocalWVDpath) -eq $false) {
    Write-Host "AVD AIB Customization - Install FSLogix : Creating directory: $LocalWVDpath"
    New-Item -Path $LocalWVDpath -ItemType Directory
}
else {
    Write-Host "AVD AIB Customization - Install FSLogix : $LocalWVDpath already exists"
}

#################################
#    Download WVD Componants    #
#################################
$FSLogixInstaller = "https://aka.ms/fslogix_download"
Write-Host "AVD AIB Customization - Install FSLogix : Downloading FSLogix from URI: $FSLogixInstaller"
Invoke-WebRequest -Uri $FSLogixInstaller -OutFile "$LocalWVDpath$FSInstaller"


##############################
#    Prep for WVD Install    #
##############################
Write-Host "AVD AIB Customization - Install FSLogix : Unzipping FSLogix installer"
Expand-Archive `
    -LiteralPath "C:\temp\wvd\$FSInstaller" `
    -DestinationPath "$LocalWVDpath\FSLogix" `
    -Force `
    -Verbose
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Set-Location $LocalWVDpath 
Write-Host "AVD AIB Customization - Install FSLogix : UnZip of FSLogix complete"


#########################
#    FSLogix Install    #
#########################
Write-Host "AVD AIB Customization - Install FSLogix : Starting to install FSLogix"
$fslogix_deploy_status = Start-Process `
    -FilePath "$LocalWVDpath\FSLogix\x64\Release\FSLogixAppsSetup.exe" `
    -ArgumentList "/install /quiet /norestart" `
    -Wait `
    -Passthru

if(!($PSBoundParameters.ContainsKey('VHDSize'))) {
    $VHDSize = "30000"
}
#######################################
#    FSLogix User Profile Settings    #
#######################################
Write-Host "AVD AIB Customization - Install FSLogix : Configure FSLogix Profile Settings"
Push-Location 
Set-Location HKLM:\SOFTWARE\
New-Item `
    -Path HKLM:\SOFTWARE\FSLogix `
    -Name Profiles `
    -Value "" `
    -Force
New-Item `
    -Path HKLM:\Software\FSLogix\Profiles\ `
    -Name Apps `
    -Force
Set-ItemProperty `
    -Path HKLM:\Software\FSLogix\Profiles `
    -Name "Enabled" `
    -Type "Dword" `
    -Value "1"

if(($PSBoundParameters.ContainsKey('ProfilePath'))) {
    New-ItemProperty `
    -Path HKLM:\Software\FSLogix\Profiles `
    -Name "CCDLocations" `
    -Value "type=smb,connectionString=$ProfilePath" `
    -PropertyType MultiString `
    -Force
}

Set-ItemProperty `
    -Path HKLM:\Software\FSLogix\Profiles `
    -Name "SizeInMBs" `
    -Type "Dword" `
    -Value $VHDSize
Set-ItemProperty `
    -Path HKLM:\Software\FSLogix\Profiles `
    -Name "IsDynamic" `
    -Type "Dword" `
    -Value "1"
Set-ItemProperty `
    -Path HKLM:\Software\FSLogix\Profiles `
    -Name "VolumeType" `
    -Type String `
    -Value "vhdx"
Set-ItemProperty `
    -Path HKLM:\Software\FSLogix\Profiles `
    -Name "FlipFlopProfileDirectoryName" `
    -Type "Dword" `
    -Value "1" 
Set-ItemProperty `
    -Path HKLM:\Software\FSLogix\Profiles `
    -Name "SIDDirNamePattern" `
    -Type String `
    -Value "%username%%sid%"
Set-ItemProperty `
    -Path HKLM:\Software\FSLogix\Profiles `
    -Name "SIDDirNameMatch" `
    -Type String `
    -Value "%username%%sid%"
Set-ItemProperty `
    -Path HKLM:\Software\FSLogix\Profiles `
    -Name DeleteLocalProfileWhenVHDShouldApply `
    -Type DWord `
    -Value 1

#Reference: https://learn.microsoft.com/en-us/azure/architecture/example-scenario/wvd/windows-virtual-desktop-fslogix#add-exclusions-for-microsoft-defender-for-cloud-by-using-powershell
Write-Host "AVD AIB Customization - Install FSLogix : Adding exclusions for Microsoft Defender"

try {
     $filelist = `
  "%ProgramFiles%\FSLogix\Apps\frxdrv.sys", `
  "%ProgramFiles%\FSLogix\Apps\frxdrvvt.sys", `
  "%ProgramFiles%\FSLogix\Apps\frxccd.sys", `
  "%TEMP%\*.VHD", `
  "%TEMP%\*.VHDX", `
  "%Windir%\TEMP\*.VHD", `
  "%Windir%\TEMP\*.VHDX" `

    $processlist = `
    "%ProgramFiles%\FSLogix\Apps\frxccd.exe", `
    "%ProgramFiles%\FSLogix\Apps\frxccds.exe", `
    "%ProgramFiles%\FSLogix\Apps\frxsvc.exe"

    Foreach($item in $filelist){
        Add-MpPreference -ExclusionPath $item}
    Foreach($item in $processlist){
        Add-MpPreference -ExclusionProcess $item}


    Add-MpPreference -ExclusionPath "%ProgramData%\FSLogix\Cache\*.VHD"
    Add-MpPreference -ExclusionPath "%ProgramData%\FSLogix\Cache\*.VHDX"
    Add-MpPreference -ExclusionPath "%ProgramData%\FSLogix\Proxy\*.VHD"
    Add-MpPreference -ExclusionPath "%ProgramData%\FSLogix\Proxy\*.VHDX"
}
catch {
     Write-Host "AVD AIB Customization - Install FSLogix : Exception occurred while adding exclusions for Microsoft Defender"
     Write-Host $PSItem.Exception
}

Write-Host "AVD AIB Customization - Install FSLogix : Finished adding exclusions for Microsoft Defender"

#Cleanup
if ((Test-Path -Path $templateFilePathFolder -ErrorAction SilentlyContinue)) {
    Remove-Item -Path $templateFilePathFolder -Force -Recurse -ErrorAction Continue
}

if ((Test-Path -Path $LocalWVDpath -ErrorAction SilentlyContinue)) {
    Remove-Item -Path $LocalWVDpath -Force -Recurse -ErrorAction Continue
}

#############
#    END    #
#############