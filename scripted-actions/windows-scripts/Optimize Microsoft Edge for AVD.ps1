#description: (PREVIEW) Configures policy settings for Microsoft Edge meant to optimize performance in AVD
#tags: Nerdio, Preview
<#
Notes:
This script configures policy settings for Microsoft Edge meant to optimize performance.
Policies Set: 
    - Enable Sleeping Tabs ("sleep" inactive browser tabs) 
    - Enable Startup Boost (preload MS Edge in the background on login)
#>

# Set registry settings
reg add HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Edge /v "SleepingTabsEnabled" /t REG_DWORD /d 1 /f
reg add HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Edge /v "StartupBoostEnabled" /t REG_DWORD /d 1 /f
