#description: Configure the clipboard transfer direction and types of data that can be copied in Azure Virtual Desktop
#execution mode: Combined
#tags: Nerdio
#Requires -RunAsAdministrator

<#
Notes:
This script configures clipboard transfer restrictions between Azure VM and Web client.
To use the script ensure it is run on VM with appropriate version of Windows
(see https://learn.microsoft.com/en-us/azure/virtual-desktop/clipboard-transfer-direction-data-types?tabs=intune#prerequisites).
On prior Widnows versions it will create required configuration, but this configuration
will not take any effect. 
#>

<#variables:
{
  "HostToClientMode": {
    "optionsSet": [
      {
        "label": "disable",
        "value": "0"
      },
      {
        "label": "plain text only",
        "value": "1"
      },
      {
        "label": "plain text and images",
        "value": "2"
      },
      {
        "label": "plain text, rich text and images",
        "value": "3"
      },
      {
        "label": "plain text, rich text, HTML and images",
        "value": "4"
      }
    ]
  },
    "ClientToHostMode": {
    "optionsSet": [
      {
        "label": "disable",
        "value": "0"
      },
      {
        "label": "plain text only",
        "value": "1"
      },
      {
        "label": "plain text and images",
        "value": "2"
      },
      {
        "label": "plain text, rich text and images",
        "value": "3"
      },
      {
        "label": "plain text, rich text, HTML and images",
        "value": "4"
      }
    ]
  }

}
#>

param (
  [ComponentModel.DisplayName('Session host to client transfer')]
  [Parameter()]
  [string] $HostToClientMode = "0",
  [ComponentModel.DisplayName('Client to session host transfer')]
  [Parameter()]
  [string] $ClientToHostMode = "1"
)
$RegPath = "HKLM:\Software\Policies\Microsoft\Windows NT\Terminal Services";
if (-not (Test-Path $RegPath)) {
    New-Item -Path $RegPath
}
New-ItemProperty -Path $RegPath -Name SCClipLevel -PropertyType DWord -Value $HostToClientMode -Force
New-ItemProperty -Path $RegPath -Name CSClipLevel -PropertyType DWord -Value $ClientToHostMode -Force
