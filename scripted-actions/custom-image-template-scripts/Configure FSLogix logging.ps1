#description: Sets FSLogix logging settings
#tags: FSLogix, Nerdio

<# Notes
- This script sets FSLogix logging settings. To customize the logging settings, modify the variables in the script.
#>

# Variables for logging settings
$LogFileKeepingPeriod = 7  # A new log file is created each day. This specifies how many to keep.
$LoggingEnabled = 2        # When set to '0', all log files are disabled. '1' for component-specific logs, '2' for all logs enabled.
$LogDir = "%ProgramData%\FSLogix\Logs"  # Specifies the location where log files should be stored. Local and UNC paths are accepted.
$LoggingLevel = 0          # Log levels: '0' - DEBUG and higher, '1' - INFO and higher, '2' - WARN and higher, '3' - ERROR and higher.
$RobocopyLogPath = ""      # Specifies a log file path for robocopy command outputs, used for troubleshooting.

# Component-specific logging settings
$ConfigTool = 1
$IEPlugin = 1
$RuleEditor = 1
$JavaRuleEditor = 1
$Service = 1
$ODFC = 1           # Enable FSLOGIX ODFC Service Logging
$Profile = 1        # Enable FSLOGIX Profile Service Logging
$FrxLauncher = 1
$RuleCompilation = 1
$Font = 1
$Network = 1
$Printer = 1
$ADSComputerGroup = 1
$DriverInterface = 1
$Search = 1
$SearchPlugin = 1
$ProcessStart = 1

# Set error action preference
$ErrorActionPreference = 'Stop'

# Main logging settings
Set-ItemProperty -Path HKLM:\Software\FSLogix\Logging -Name "LogFileKeepingPeriod" -Type Dword -Value $LogFileKeepingPeriod
Set-ItemProperty -Path HKLM:\Software\FSLogix\Logging -Name "LoggingEnabled" -Type Dword -Value $LoggingEnabled
Set-ItemProperty -Path HKLM:\Software\FSLogix\Logging -Name "LogDir" -Type String -Value $LogDir
Set-ItemProperty -Path HKLM:\Software\FSLogix\Logging -Name "LoggingLevel" -Type Dword -Value $LoggingLevel
Set-ItemProperty -Path HKLM:\Software\FSLogix\Logging -Name "RobocopyLogPath" -Type REG_SZ -Value $RobocopyLogPath

# Component specific log files
Set-ItemProperty -Path HKLM:\Software\FSLogix\Logging -Name "ConfigTool" -Type Dword -Value $ConfigTool
Set-ItemProperty -Path HKLM:\Software\FSLogix\Logging -Name "IEPlugin" -Type Dword -Value $IEPlugin
Set-ItemProperty -Path HKLM:\Software\FSLogix\Logging -Name "RuleEditor" -Type Dword -Value $RuleEditor
Set-ItemProperty -Path HKLM:\Software\FSLogix\Logging -Name "JavaRuleEditor" -Type Dword -Value $JavaRuleEditor
Set-ItemProperty -Path HKLM:\Software\FSLogix\Logging -Name "Service" -Type Dword -Value $Service
Set-ItemProperty -Path HKLM:\Software\FSLogix\Logging -Name "ODFC" -Type Dword -Value $ODFC
Set-ItemProperty -Path HKLM:\Software\FSLogix\Logging -Name "Profile" -Type Dword -Value $Profile
Set-ItemProperty -Path HKLM:\Software\FSLogix\Logging -Name "FrxLauncher" -Type Dword -Value $FrxLauncher
Set-ItemProperty -Path HKLM:\Software\FSLogix\Logging -Name "RuleCompilation" -Type Dword -Value $RuleCompilation
Set-ItemProperty -Path HKLM:\Software\FSLogix\Logging -Name "Font" -Type Dword -Value $Font
Set-ItemProperty -Path HKLM:\Software\FSLogix\Logging -Name "Network" -Type Dword -Value $Network
Set-ItemProperty -Path HKLM:\Software\FSLogix\Logging -Name "Printer" -Type Dword -Value $Printer
Set-ItemProperty -Path HKLM:\Software\FSLogix\Logging -Name "ADSComputerGroup" -Type Dword -Value $ADSComputerGroup
Set-ItemProperty -Path HKLM:\Software\FSLogix\Logging -Name "DriverInterface" -Type Dword -Value $DriverInterface
Set-ItemProperty -Path HKLM:\Software\FSLogix\Logging -Name "Search" -Type Dword -Value $Search
Set-ItemProperty -Path HKLM:\Software\FSLogix\Logging -Name "SearchPlugin" -Type Dword -Value $SearchPlugin
Set-ItemProperty -Path HKLM:\Software\FSLogix\Logging -Name "ProcessStart" -Type Dword -Value $ProcessStart
