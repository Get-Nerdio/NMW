<#
  .SYNOPSIS
    Downloads installer exe & installs Crowdstrike
  .DESCRIPTION
    PreReq:
		-Nerdio Secure Variables:
			- CrowdstrikeID - The CID for the Organization
			- CsInstaller - The public URI for the CsInstaller.
				
		The install-crowdstrike.ps1 script runs the Crowdstrike Falcon VDI installer (VDI=1) on a session host in AVD.
  .NOTES
    Company:  Steel Root, Inc.
    Website:  steelroot.us
    Created:  2021-07-19
    Modified: 2021-12-22
#>

#Link to .exe on Public Storage
$PublicUrl = $SecureVars.CsInstaller

#Local directory to keep the installer
$LocalDirectory = 'C:\Temp\'

#Local Directory + the filename obtained from the URL 
#Sorry this is stupid long, but it's looking at host many things are returned when you split"/",
#then grabbing the very last one of them, aka the filename + extenson
$LocalFile ="$LocalDirectory"+ ($PublicUrl.split("/") | Select-Object -Last 1)


# Create a TEMP directory if one does not already exist
if (!(Test-Path -Path '$LocalDirectory' -ErrorAction SilentlyContinue)) {
    #Creates the directory
    New-Item -ItemType Directory -Path $LocalDirectory -Force -Verbose
}

#Download Sensor from the SRPublic Share to the Local Directory
Invoke-WebRequest -Uri $PublicUrl -OutFile $LocalFile -Verbose

# Is the Service already running? If so, skip the installer.
if (!(Get-Service -Name 'CSFalconService' -ErrorAction SilentlyContinue)) {

    #Runs the installer with the appropriate flags. VDI=1 uses the fqdn of the host. For Images, replace with NO_START=1
    & $LocalFile /install /quiet /norestart CID=$($SecureVars.CrowdstrikeID) VDI=1
}

#Remove Installer
Remove-Item -Path $LocalFile

#Remove Directory (if it's empty)
if ((Get-ChildItem -Path $LocalDirectory).count -eq 0){
    #Directory Is Empty
    Remove-Item -Path $LocalDirectory -Verbose
}
