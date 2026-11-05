#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$UnattendPath = 'C:\ProgramData\SimpleVDI\Unattend.xml',
    [switch]$KeepScript
)

$ErrorActionPreference = 'Stop'

function Test-PendingReboot {
    $locations = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($location in $locations) {
        if (Test-Path -LiteralPath $location) { return $true }
    }

    $sessionManager = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue
    return [bool]($sessionManager -and $sessionManager.PendingFileRenameOperations)
}

function Remove-MaintenanceScript {
    if ($KeepScript -or -not $PSCommandPath) { return }
    try {
        $launcherPath = Join-Path (Split-Path -Parent $PSCommandPath) 'Maintenance-Reseal.cmd'
        if (Test-Path -LiteralPath $launcherPath -PathType Leaf) {
            Remove-Item -LiteralPath $launcherPath -Force -ErrorAction Stop
            Write-Host "Removed maintenance launcher: $launcherPath"
        }
        Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction Stop
        Write-Host "Removed maintenance script: $PSCommandPath"
    } catch {
        throw "Sysprep succeeded, but the maintenance files could not be removed: $($_.Exception.Message). Delete Maintenance-Reseal.ps1 and Maintenance-Reseal.cmd manually before publishing the template."
    }
}

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated Windows PowerShell window.'
}

$computer = Get-CimInstance Win32_ComputerSystem
if ($computer.PartOfDomain) {
    throw "This maintenance VM is still joined to '$($computer.Domain)'. Remove it from the domain and reboot before resealing."
}

$sysprep = Join-Path $env:windir 'System32\Sysprep\Sysprep.exe'
if (-not (Test-Path -LiteralPath $sysprep -PathType Leaf)) {
    throw "Sysprep.exe was not found at $sysprep."
}
if (-not (Test-Path -LiteralPath $UnattendPath -PathType Leaf)) {
    throw "The existing template answer file was not found: $UnattendPath. Do not reseal this VM without the original template preparation file."
}

$admin = Get-LocalUser -Name Admin -ErrorAction SilentlyContinue
if (-not $admin) { throw "The local template account 'Admin' was not found." }
if (-not $admin.Enabled) { throw "The local template account 'Admin' is disabled." }

if (Test-PendingReboot) {
    throw 'Windows reports a pending reboot. Reboot the maintenance VM, allow Windows Update to finish, then run this script again.'
}

$unattendFullPath = [IO.Path]::GetFullPath($UnattendPath)
Write-Host 'Maintenance checks passed.'
Write-Host 'Do not power off or interrupt this VM while Sysprep is running.'
Write-Host "Using answer file: $unattendFullPath"
Write-Host 'Starting Sysprep generalization. The VM will be shut down after successful cleanup.'

$process = Start-Process -FilePath $sysprep -ArgumentList @(
    '/generalize',
    '/oobe',
    '/quit',
    "/unattend:`"$unattendFullPath`""
) -PassThru -Wait

if ($process.ExitCode -ne 0) {
    throw "Sysprep failed (exit code $($process.ExitCode)). Inspect $env:windir\System32\Sysprep\Panther\setuperr.log before retrying."
}

Remove-MaintenanceScript
Write-Host 'Sysprep succeeded. Keep the VM powered off and convert it to a new AOC VM template.'

& "$env:windir\System32\shutdown.exe" /s /t 0
if ($LASTEXITCODE -ne 0) {
    throw 'Sysprep succeeded, but shutdown failed. Shut down Windows manually and keep the VM powered off before publishing.'
}
