<#
SPDX-License-Identifier: GPL-2.0-or-later

AcerBattery.ps1 - Acer battery health control for Windows 10/11
Port of acer-wmi-battery 0.2.0 (Linux kernel driver by Frederik Harwath).

The Linux driver calls ACPI-WMI GUID {79772EC5-04B1-4bfd-843C-61E7F77B6CC9}.
Windows' in-box ACPI-WMI mapper (wmiacpi.sys) exposes that GUID as the class
root\WMI:BatteryControl, so this script calls the same firmware methods
(19 GetBattInfoInterface, 20 GetBatteryHealthControlStatus,
21 SetBatteryHealthControl) without needing a kernel driver.

Usage
    AcerBattery.ps1                       interactive menu
    AcerBattery.ps1 status                modes, temperature, persistence
    AcerBattery.ps1 health [on|off]       read (1/0/-1) or set the ~80% limit
    AcerBattery.ps1 calibration [on|off]  read or start/stop calibration
    AcerBattery.ps1 temp                  battery temperature
    AcerBattery.ps1 persist on|off|remove re-apply health mode at boot/resume
    AcerBattery.ps1 raw                   raw firmware replies (debug)
    Options: -Force (skip AC check for calibration), -Verbose

Requires Administrator; the script elevates itself through UAC.

Exit codes: 0 ok, 1 firmware/WMI error (-EIO), 2 interface missing (-ENODEV),
            3 mode not supported, 4 bad argument, 5 not elevated
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'status', 'health', 'calibration', 'temp', 'persist', 'raw', 'help')]
    [string]$Command = 'menu',

    [Parameter(Position = 1)]
    [string]$Value,

    [switch]$Force,      # skip the AC-adapter check when starting calibration
    [switch]$NoElevate,  # internal / scheduled task: never prompt for UAC
    [string]$OutFile     # internal: elevated child writes its output here
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants (mirroring acer-wmi-battery.c)
# ---------------------------------------------------------------------------
$WMI_GUID           = '{79772EC5-04B1-4bfd-843C-61E7F77B6CC9}'
$ACER_BATTERY_INDEX = [byte]1     # Acer Care Center always uses battery 1
$HEALTH_MODE        = [byte]1     # enum battery_mode
$CALIBRATION_MODE   = [byte]2
$SBS_TEMPERATURE    = [uint32]8   # Smart Battery Data Spec, unit 0.1 K

$TaskName   = 'AcerWmiBattery-HealthMode'
$InstallDir = Join-Path $env:ProgramFiles 'AcerWmiBattery'
$LogDir     = Join-Path $env:ProgramData  'AcerWmiBattery'
$LogFile    = Join-Path $LogDir 'acer-wmi-battery.log'

$EXIT_OK = 0; $EXIT_EIO = 1; $EXIT_ENODEV = 2; $EXIT_UNSUPPORTED = 3
$EXIT_BADARG = 4; $EXIT_NOADMIN = 5

# ---------------------------------------------------------------------------
# Errors: exit code travels in Exception.Data (no script classes, PS 5.1-safe)
# ---------------------------------------------------------------------------
function New-AcerError([string]$Message, [int]$Code) {
    $e = New-Object System.InvalidOperationException $Message
    $e.Data['AcerExitCode'] = $Code
    return $e
}

function Get-AcerExitCode($Exception) {
    if ($Exception.Data.Contains('AcerExitCode')) { return [int]$Exception.Data['AcerExitCode'] }
    return $null
}

# ---------------------------------------------------------------------------
# Output / logging
# ---------------------------------------------------------------------------
function Write-Out([string]$Text, [switch]$IsError) {
    if ($IsError) { Write-Host $Text -ForegroundColor Red } else { Write-Host $Text }
    if ($OutFile) { Add-Content -LiteralPath $OutFile -Value $Text -Encoding UTF8 }
}

function Write-Log([string]$Text) {
    try {
        if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        Add-Content -LiteralPath $LogFile -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Text) -Encoding UTF8
    } catch { }   # logging must never break the actual operation
}

function Test-IsAdmin {
    $p = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-Bool([string]$s) {
    # kstrtobool()-style parsing, as the sysfs store functions use
    switch -Regex ($s.Trim().ToLowerInvariant()) {
        '^(1|y|yes|on|true|enable|enabled)$'    { return $true }
        '^(0|n|no|off|false|disable|disabled)$' { return $false }
    }
    throw (New-AcerError "Invalid value '$s' (use on or off)." $EXIT_BADARG)
}

function Test-OnAC {
    # $true / $false, or $null if unknown
    try {
        return (@(Get-CimInstance -Namespace root/wmi -ClassName BatteryStatus -ErrorAction Stop |
                  Where-Object { $_.PowerOnline }).Count -gt 0)
    } catch { return $null }
}

# ---------------------------------------------------------------------------
# WMI transport (wmi_has_guid / wmi_evaluate_method)
# ---------------------------------------------------------------------------
$script:BatteryControl = $null

function Get-BatteryControl {
    if ($script:BatteryControl) { return $script:BatteryControl }
    $all = @()
    try { $all = @(Get-CimInstance -Namespace root/wmi -ClassName BatteryControl -ErrorAction Stop) } catch { }
    if ($all.Count -eq 0) {
        throw (New-AcerError ("Acer battery interface $WMI_GUID (root\WMI:BatteryControl) not found. " +
            'This model/BIOS does not expose it.') $EXIT_ENODEV)
    }
    $active = @($all | Where-Object { $_.CimInstanceProperties['Active'] -and $_.CimInstanceProperties['Active'].Value })
    $script:BatteryControl = if ($active.Count -gt 0) { $active[0] } else { $all[0] }
    return $script:BatteryControl
}

function Invoke-BatteryMethod([string]$Method, [hashtable]$Arguments) {
    $inst = Get-BatteryControl
    try {
        $r = Invoke-CimMethod -InputObject $inst -MethodName $Method -Arguments $Arguments -ErrorAction Stop
    } catch {
        throw (New-AcerError "WMI method $Method failed: $($_.Exception.Message)" $EXIT_EIO)
    }

    # Windows PowerShell 5.1 returns an adapted object (one property per [out]
    # parameter); some hosts return a CimMethodResult with .OutParameters.
    $out = @{}
    if ($r.PSObject.Properties['OutParameters']) {
        foreach ($p in $r.OutParameters) { $out[[string]$p.Name] = $p.Value }
    } else {
        foreach ($p in $r.PSObject.Properties) {
            if ($p.Name -notin 'PSComputerName', 'ReturnValue') { $out[[string]$p.Name] = $p.Value }
        }
    }
    foreach ($k in $out.Keys) { Write-Verbose ('{0}: {1} = {2}' -f $Method, $k, (@($out[$k]) -join ',')) }
    return $out
}

# ---------------------------------------------------------------------------
# Firmware calls (ports of the C functions)
# ---------------------------------------------------------------------------

# get_battery_information() - method 19
function Get-BatteryInformation([uint32]$Index) {
    $o = Invoke-BatteryMethod 'GetBattInfoInterface' @{
        uBatteryInfoIndex = $Index
        uBatteryNo        = [uint32]$ACER_BATTERY_INDEX
    }
    if (-not $o.ContainsKey('uReturn') -or $null -eq $o['uReturn']) {
        throw (New-AcerError 'GetBattInfoInterface returned no data.' $EXIT_EIO)
    }
    return [uint32]$o['uReturn']
}

# get_battery_health_control_status() - method 20
# health_mode / calibration_mode: -1 not supported, 0 off, 1 on
function Get-BatteryHealthControlStatus {
    $o = Invoke-BatteryMethod 'GetBatteryHealthControlStatus' @{
        uBatteryNo     = $ACER_BATTERY_INDEX
        uFunctionQuery = [byte]1
        uReserved      = [byte[]](0, 0)
    }
    if (-not ($o.ContainsKey('uFunctionList') -and $o.ContainsKey('uFunctionStatus'))) {
        throw (New-AcerError ('Unexpected firmware reply, fields: ' + (($o.Keys | Sort-Object) -join ', ')) $EXIT_EIO)
    }
    $list   = [byte]$o['uFunctionList']
    $status = @($o['uFunctionStatus'])
    if ($status.Count -lt 2) {
        throw (New-AcerError "Firmware returned $($status.Count) status byte(s), expected 5." $EXIT_EIO)
    }
    [pscustomobject]@{
        health_mode      = if ($list -band $HEALTH_MODE)      { [int]([byte]$status[0] -gt 0) } else { -1 }
        calibration_mode = if ($list -band $CALIBRATION_MODE) { [int]([byte]$status[1] -gt 0) } else { -1 }
        uFunctionList    = $list
        uReturn          = @($o['uReturn'])
        uFunctionStatus  = $status
    }
}

# set_battery_health_control() - method 21
# Like the Linux driver, the firmware return code is not trusted; Set-Mode reads back.
function Set-BatteryHealthControl([byte]$Function, [bool]$Enable) {
    $o = Invoke-BatteryMethod 'SetBatteryHealthControl' @{
        uBatteryNo      = $ACER_BATTERY_INDEX
        uFunctionMask   = $Function
        uFunctionStatus = [byte][int]$Enable
        uReservedIn     = [byte[]](0, 0, 0, 0, 0)
    }
    if ($o.ContainsKey('uReturn')) { Write-Verbose ('SetBatteryHealthControl uReturn = {0}' -f $o['uReturn']) }
}

# temperature_show(): 0.1 K -> degrees C
function Get-TemperatureText {
    $v = Get-BatteryInformation $SBS_TEMPERATURE
    if ($v -gt [uint16]::MaxValue) { throw (New-AcerError "Temperature value out of range ($v)." $EXIT_EIO) }
    return ('{0:N1} {1}C' -f (([int]$v - 2731) / 10.0), [char]0x00B0)
}

# ---------------------------------------------------------------------------
# Operations
# ---------------------------------------------------------------------------
function Format-Mode([int]$v) {
    if ($v -lt 0) { return 'not supported' }
    if ($v -eq 0) { return 'off' }
    return 'on'
}

function Get-PersistState {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) { return 'disabled' }
    if ($t.Actions[0].Arguments -match 'health off') { return 'enabled (forces health OFF)' }
    return 'enabled (forces health ON)'
}

function Show-Status {
    $s = Get-BatteryHealthControlStatus
    $temp = $(try { Get-TemperatureText } catch { 'unavailable' })
    Write-Out ('Health mode      : {0}{1}' -f (Format-Mode $s.health_mode), $(if ($s.health_mode -gt 0) { '  (charge limited to ~80%)' } else { '' }))
    Write-Out ('Calibration mode : {0}' -f (Format-Mode $s.calibration_mode))
    Write-Out ('Temperature      : {0}' -f $temp)
    Write-Out ('Persist at boot  : {0}' -f (Get-PersistState))
}

function Show-Raw {
    $s = Get-BatteryHealthControlStatus
    Write-Out ('GetBatteryHealthControlStatus: uFunctionList=0x{0:X2} uReturn=[{1}] uFunctionStatus=[{2}]' -f `
        $s.uFunctionList, ($s.uReturn -join ', '), ($s.uFunctionStatus -join ', '))
    Write-Out ('GetBattInfoInterface(0x8): uReturn={0}' -f (Get-BatteryInformation $SBS_TEMPERATURE))
}

# health_mode_store() / calibration_mode_store() + update_state()
function Set-Mode([string]$Mode, [bool]$Enable) {
    $fn   = if ($Mode -eq 'health') { $HEALTH_MODE } else { $CALIBRATION_MODE }
    $prop = "${Mode}_mode"

    if ((Get-BatteryHealthControlStatus).$prop -lt 0) {
        throw (New-AcerError "$Mode mode is not supported by this firmware." $EXIT_UNSUPPORTED)
    }
    if ($Mode -eq 'calibration' -and $Enable -and -not $Force -and (Test-OnAC) -eq $false) {
        throw (New-AcerError 'Connect the AC adapter before starting calibration (or use -Force).' $EXIT_BADARG)
    }

    Set-BatteryHealthControl $fn $Enable

    $want = [int]$Enable
    for ($i = 0; $i -lt 5; $i++) {
        $now = (Get-BatteryHealthControlStatus).$prop
        if ($now -eq $want) { break }
        Start-Sleep -Milliseconds 500
    }
    if ($now -ne $want) {
        throw (New-AcerError "Firmware did not apply the change; $Mode mode is still $(Format-Mode $now)." $EXIT_EIO)
    }

    $msg = '{0} mode {1}' -f $Mode, $(if ($Enable) { 'enabled' } else { 'disabled' })
    Write-Out $msg
    Write-Log $msg
    if ($Mode -eq 'calibration' -and $Enable) {
        Write-Out 'Keep the laptop on AC. Completion is not detected automatically;'
        Write-Out 'turn calibration off when the charge/discharge/charge cycle is finished.'
    }
}

# Equivalent of "insmod acer-wmi-battery.ko enable_health_mode=1", applied at
# every boot and resume by a SYSTEM scheduled task.
function Install-Persistence([bool]$Enable) {
    $state  = if ($Enable) { 'on' } else { 'off' }
    $target = Join-Path $InstallDir 'AcerBattery.ps1'
    if (-not (Test-Path -LiteralPath $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
    if ($PSCommandPath -ne $target) { Copy-Item -LiteralPath $PSCommandPath -Destination $target -Force }

    $psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $psExe -Argument (
        "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$target`" health $state -NoElevate")

    $boot = New-ScheduledTaskTrigger -AtStartup
    $boot.Delay = 'PT20S'

    # Resume from sleep/hibernate: System log, Power-Troubleshooter event 1
    $resume = New-CimInstance -ClientOnly -CimClass (
        Get-CimClass -Namespace Root/Microsoft/Windows/TaskScheduler -ClassName MSFT_TaskEventTrigger)
    $resume.Enabled = $true
    $resume.Delay   = 'PT10S'
    $resume.Subscription = '<QueryList><Query Id="0" Path="System"><Select Path="System">' +
        "*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]" +
        '</Select></Query></QueryList>'

    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($boot, $resume) `
        -Principal $principal -Settings $settings -Force `
        -Description "Re-applies Acer battery health mode ($state) at boot and resume." | Out-Null

    Write-Out "Task '$TaskName' installed: health mode $state at every boot and resume."
    Write-Log "persistence installed (health $state)"
    Set-Mode 'health' $Enable
}

function Remove-Persistence {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Out "Task '$TaskName' removed (current battery setting unchanged)."
    } else {
        Write-Out 'Boot/resume task was not installed.'
    }
    Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log 'persistence removed'
}

# ---------------------------------------------------------------------------
# Interactive menu
# ---------------------------------------------------------------------------
function Invoke-MenuAction([scriptblock]$Action) {
    try { & $Action }
    catch {
        Write-Out ('Error: ' + $_.Exception.Message) -IsError
        Write-Log ('error: ' + $_.Exception.Message)
    }
}

function Show-MenuHeader {
    Write-Host ''
    Write-Host '  ==============================================' -ForegroundColor Cyan
    Write-Host '        Acer Battery Health Control'              -ForegroundColor Cyan
    Write-Host '  ==============================================' -ForegroundColor Cyan
    try {
        $s = Get-BatteryHealthControlStatus
        $hc = if ($s.health_mode -gt 0) { 'Green' } elseif ($s.health_mode -eq 0) { 'Yellow' } else { 'DarkGray' }
        Write-Host '   Health mode (80% limit) : ' -NoNewline; Write-Host (Format-Mode $s.health_mode) -ForegroundColor $hc
        Write-Host ('   Calibration mode        : ' + (Format-Mode $s.calibration_mode))
    } catch {
        Write-Host ('   Status unavailable: ' + $_.Exception.Message) -ForegroundColor Red
    }
    try { Write-Host ('   Battery temperature     : ' + (Get-TemperatureText)) } catch { }
    $b = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($b) {
        $onAC = Test-OnAC
        $ac = if ($onAC -eq $true) { ', on AC' } elseif ($onAC -eq $false) { ', on battery' } else { '' }
        Write-Host ('   Charge                  : {0}%{1}' -f $b.EstimatedChargeRemaining, $ac)
    }
    Write-Host ('   Re-apply at boot/resume : ' + (Get-PersistState))
    Write-Host '  ----------------------------------------------' -ForegroundColor Cyan
}

function Show-Menu {
    try { $Host.UI.RawUI.WindowTitle = 'Acer Battery Health Control' } catch { }
    while ($true) {
        Clear-Host
        Show-MenuHeader
        Write-Host '   [1] Health mode ON   (limit charge to ~80%)'
        Write-Host '   [2] Health mode OFF  (charge to 100%)'
        Write-Host '   [3] Start battery calibration (AC required)'
        Write-Host '   [4] Stop battery calibration'
        Write-Host '   [5] Keep health mode ON after every boot/resume'
        Write-Host '   [6] Remove boot/resume task'
        Write-Host '   [7] Raw firmware data (debug)'
        Write-Host '   [8] Open log file'
        Write-Host '   [R] Refresh   [Q] Quit'
        Write-Host ''
        $choice = ([string](Read-Host '  Select option')).Trim().ToUpperInvariant()
        Write-Host ''

        $wait = $true
        switch ($choice) {
            '1' { Invoke-MenuAction { Set-Mode 'health' $true } }
            '2' { Invoke-MenuAction { Set-Mode 'health' $false } }
            '3' {
                Write-Host '  Calibration charges to 100%, discharges and recharges; this takes hours.' -ForegroundColor Yellow
                if ((Read-Host '  Start calibration? (y/N)') -match '^(y|yes)$') {
                    Invoke-MenuAction { Set-Mode 'calibration' $true }
                } else { Write-Host '  Cancelled.' }
            }
            '4' { Invoke-MenuAction { Set-Mode 'calibration' $false } }
            '5' { Invoke-MenuAction { Install-Persistence $true } }
            '6' { Invoke-MenuAction { Remove-Persistence } }
            '7' { Invoke-MenuAction { Show-Raw } }
            '8' {
                if (Test-Path -LiteralPath $LogFile) { Start-Process notepad.exe -ArgumentList "`"$LogFile`"" }
                else { Write-Host '  No log file yet.' }
            }
            'Q' { return }
            { $_ -in 'R', '' } { $wait = $false }
            default { Write-Host "  Unknown option '$choice'." -ForegroundColor Red }
        }
        if ($wait) { Read-Host "`n  Press Enter to return to the menu" | Out-Null }
    }
}

# ---------------------------------------------------------------------------
# Elevation
# ---------------------------------------------------------------------------
function Get-SelfArgs([string[]]$Extra) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", $Command)
    if ($Value) { $a += $Value }
    if ($Force) { $a += '-Force' }
    if ($VerbosePreference -eq 'Continue') { $a += '-Verbose' }
    return $a + $Extra
}

# Menu: open it in a new elevated window; this window can close.
function Start-ElevatedMenu {
    try {
        Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList (Get-SelfArgs @('-NoElevate')) -Verb RunAs | Out-Null
        return $EXIT_OK
    } catch {
        Write-Out 'Administrator rights are required (UAC prompt was cancelled).' -IsError
        return $EXIT_NOADMIN
    }
}

# Commands: run elevated in a hidden window and print its output here.
function Invoke-Elevated {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('acerbatt_{0}.txt' -f [guid]::NewGuid().ToString('N'))
    try {
        $p = Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -WindowStyle Hidden -Wait -PassThru `
                -ArgumentList (Get-SelfArgs @('-NoElevate', '-OutFile', "`"$tmp`""))
    } catch {
        Write-Out 'Administrator rights are required (UAC prompt was cancelled).' -IsError
        return $EXIT_NOADMIN
    }
    if (Test-Path -LiteralPath $tmp) {
        Get-Content -LiteralPath $tmp -Encoding UTF8 | ForEach-Object { Write-Host $_ }
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    } elseif ($p.ExitCode -ne 0) {
        Write-Out "Elevated run failed with exit code $($p.ExitCode). Run it from an Administrator PowerShell to see details." -IsError
    }
    return $p.ExitCode
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if ($Command -eq 'help') {
    # print the "Usage" section of the header comment
    $lines = Get-Content -LiteralPath $PSCommandPath -TotalCount 25
    $start = [array]::IndexOf($lines, 'Usage')
    if ($start -ge 0) { $lines[$start..($start + 9)] | ForEach-Object { Write-Host $_ } }
    exit $EXIT_OK
}

if (-not (Test-IsAdmin)) {
    if ($NoElevate) {
        Write-Out 'This must be run as Administrator.' -IsError
        exit $EXIT_NOADMIN
    }
    if ($Command -eq 'menu') { exit (Start-ElevatedMenu) }
    exit (Invoke-Elevated)
}

$code = $EXIT_OK
try {
    switch ($Command) {
        'menu'   { Show-Menu }
        'status' { Show-Status }
        'raw'    { Show-Raw }
        'temp'   { Write-Out (Get-TemperatureText) }
        { $_ -in 'health', 'calibration' } {
            if ([string]::IsNullOrWhiteSpace($Value)) {
                Write-Out ([string](Get-BatteryHealthControlStatus)."${Command}_mode")   # like cat sysfs
            } else {
                Set-Mode $Command (ConvertTo-Bool $Value)
            }
        }
        'persist' {
            if ($Value -match '^\s*(remove|uninstall)\s*$') { Remove-Persistence }
            elseif ([string]::IsNullOrWhiteSpace($Value)) { throw (New-AcerError 'Usage: persist on|off|remove' $EXIT_BADARG) }
            else { Install-Persistence (ConvertTo-Bool $Value) }
        }
    }
} catch {
    $code = Get-AcerExitCode $_.Exception
    if ($null -eq $code) {
        $code = $EXIT_EIO
        Write-Log ('unexpected error: ' + $_.Exception.Message + "`r`n" + $_.ScriptStackTrace)
        Write-Out $_.ScriptStackTrace -IsError
    } else {
        Write-Log ('error: ' + $_.Exception.Message)
    }
    Write-Out ('acer-wmi-battery: ' + $_.Exception.Message) -IsError
}
exit $code
