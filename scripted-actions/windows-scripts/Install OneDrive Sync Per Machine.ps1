#description: Downloads and installs OneDrive for all users
#tags: Nerdio, Preview

<#
Notes:
This script will download the OneDriveSetup.exe file from the Microsoft link and install it for all users.
#>

# Define the URL of the OneDriveSetup.exe file
$OneDriveSetupUrl = "https://go.microsoft.com/fwlink/?linkid=844652"

# Define the path where the OneDriveSetup.exe file will be downloaded
$DownloadPath = "C:\Temp\OneDriveSetup.exe"

# Create the directory if it doesn't exist
if (!(Test-Path -Path "C:\Temp")) {
    New-Item -ItemType Directory -Path "C:\Temp"
}

# Download the OneDriveSetup.exe file
Invoke-WebRequest -Uri $OneDriveSetupUrl -OutFile $DownloadPath

# Execute the OneDriveSetup.exe file with the /allusers flag
$process = Start-Process -FilePath $DownloadPath -ArgumentList "/allusers", "/silent" -PassThru
$process.WaitForExit()

### End Script ###
