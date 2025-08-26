#description: Install the ThreatLocker Workstation.
#execution mode: Individual
#tags: Nerdio, ThreatLocker

<#
Notes:
The installation script requires an ThreatLocker GroupId.
You must provide secure variables to this script as seen in the Required Variables section. 
Set these up in Nerdio Manager under Settings->Environment->Nerdio->Secure variables. The variables to create are:
    ThreatLockerGroupId
#>

##### Required Variables #####

$groupId = $SecureVars.ThreatLockerGroupId

##### Script Logic #####

if (!(Test-Path "C:\Temp")) {
    mkdir "C:\Temp";
}

if ([Environment]::Is64BitOperatingSystem) {
    $downloadURL = "https://api.threatlocker.com/installers/threatlockerstubx64.exe";
}
else {
    $downloadURL = "https://api.threatlocker.com/installers/threatlockerstubx86.exe";
}

$localInstaller = "C:\Temp\ThreatLockerStub.exe";
Invoke-WebRequest -Uri $downloadURL -OutFile $localInstaller;
& C:\Temp\ThreatLockerStub.exe InstallKey=$groupId;