#requires -Version 7.2
[CmdletBinding()]
param([string]$ConfigPath="$PSScriptRoot\init.json",[Parameter(Mandatory)][string]$StatePath)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/lib/Config.ps1"
$legacyStatePath=[IO.Path]::GetFullPath($StatePath)
$ConfigPath=Resolve-DeploymentFilePath $ConfigPath
$StatePath=Resolve-DeploymentFilePath $StatePath
$config=Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
foreach ($role in @('Aoc','Local','Domain','Horizon')) {
    $config.Remove("${role}Password")
    $config["${role}Username"]=Read-Host "$role username used for this batch (no password required)"
}
$state=Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json -AsHashtable
Write-Output "Configuration: $($ConfigPath)"
Write-Output "State: $($StatePath)"
if ($legacyStatePath -ine $StatePath -and (Test-Path -LiteralPath $legacyStatePath)) {
    Write-Output "WARNING: Another state file exists at the legacy process-relative path: $legacyStatePath"
    foreach ($candidatePath in @($StatePath,$legacyStatePath)) {
        $candidateState=Get-Content -LiteralPath $candidatePath -Raw | ConvertFrom-Json -AsHashtable
        $file=Get-Item -LiteralPath $candidatePath
        [pscustomobject]@{StateFile=$candidatePath;Compatibility=(Get-ConfigCompatibilityReason $config $candidateState.ConfigHash);LastWriteTime=$file.LastWriteTime;Entries=$candidateState.Entries.Count;FirstVM=$candidateState.Entries[0].Hostname;FirstVmId=$candidateState.Entries[0].VmId;FirstTag=$candidateState.Entries[0].Tag;FirstPhase=$candidateState.Entries[0].Phase} | Format-List
    }
}
$reason=Get-ConfigCompatibilityReason $config $state.ConfigHash
if ($reason) {Write-Output "Current compatibility: $reason"}
else {Write-Output 'Current compatibility: NO MATCH. No state was changed.'}
$directory=Split-Path ($ConfigPath)
$baseName=[IO.Path]::GetFileName($ConfigPath)
$backups=@(Get-ChildItem -LiteralPath $directory -File | Where-Object {$_.Name -like "$baseName*" -and $_.FullName -ne $ConfigPath})
foreach ($file in $backups) {
    try {$backup=Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable} catch {continue}
    $match=Get-ConfigCompatibilityReason $backup $state.ConfigHash
    $changed=@(foreach ($key in @(@($config.Keys)+@($backup.Keys) | Sort-Object -Unique)) {
        if ($key -match 'Password$') {continue}
        if (-not $config.ContainsKey($key) -or -not $backup.ContainsKey($key) -or (ConvertTo-Json -InputObject $config[$key] -Depth 20 -Compress) -cne (ConvertTo-Json -InputObject $backup[$key] -Depth 20 -Compress)) {$key}
    })
    [pscustomobject]@{Backup=$file.Name;MatchesBatch=[bool]$match;MatchReason=$match;ChangedPublicFields=($changed -join ', ')} | Format-List
}
if ($backups.Count -eq 0) {Write-Output 'No configuration backups found beside the configuration file.'}
if ($state.ContainsKey('PublicConfig')) {
    $changed=@(foreach ($key in @(@($config.Keys)+@($state.PublicConfig.Keys) | Sort-Object -Unique)) {
        if ($key -match 'Password$') {continue}
        if (-not $config.ContainsKey($key) -or -not $state.PublicConfig.ContainsKey($key) -or (ConvertTo-Json -InputObject $config[$key] -Depth 20 -Compress) -cne (ConvertTo-Json -InputObject $state.PublicConfig[$key] -Depth 20 -Compress)) {$key}
    })
    Write-Output "Changed public fields compared with saved snapshot: $($changed -join ', ')"
} else {Write-Output 'Legacy state has no saved configuration snapshot. Its hash alone cannot identify the original changed field.'}
