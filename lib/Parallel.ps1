. "$PSScriptRoot/State.ps1"
function Save-ParallelEntry($Context,$Entry) {
    # Snapshot each private worker entry; merge and persist under one shared lock.
    $snapshot=$Entry | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
    [Threading.Monitor]::Enter($Context.Gate)
    try {
        $index=-1
        for ($i=0;$i -lt $Context.State.Entries.Count;$i++) {
            if ($Context.State.Entries[$i].Tag -eq $snapshot.Tag) {$index=$i;break}
        }
        if ($index -lt 0) {throw 'Worker state ownership mismatch.'}
        $Context.State.Entries[$index]=$snapshot
        Write-DeploymentStateFile -Path $Context.StateFile -Value $Context.State
    } finally {[Threading.Monitor]::Exit($Context.Gate)}
}
function Invoke-ParallelDeployment($Entries,[int]$Concurrency,$Context,[string]$Runner) {
    $snapshots=@($Entries | ForEach-Object {ConvertTo-Json -InputObject $_ -Depth 20 -Compress})
    $workerText=@'
param($context,$entry,$runnerText,[bool]$provisionOnly)
try { & ([scriptblock]::Create($runnerText)) $context $entry $provisionOnly }
catch {
    $message=($_.Exception.Message -split '[\r\n]')[0]
    . (Join-Path $context.Root 'lib/Aoc.ps1')
    foreach ($secret in @(Get-AocRequestSecrets $context.Config)) {
        if ($secret) {$message=$message.Replace($secret,'[REDACTED]')}
    }
    $entry.Error=$message
    . (Join-Path $context.Root 'lib/Parallel.ps1')
    Save-ParallelEntry $context $entry
    Write-Warning "$($entry.Hostname): worker failed: $message"
    [pscustomobject]@{Hostname=$entry.Hostname;Succeeded=$false;Entry=$entry}
}
'@
    if ($Context.ContainsKey('PipelineProvisioning') -and $Context.PipelineProvisioning) {
        # Two independent runspace pools: waiting guests cannot occupy clone workers.
        $snapshots | ForEach-Object -ThrottleLimit $Context.CloneConcurrency -Parallel {
            $context=$using:Context;$runnerText=$using:Runner;$worker=$using:workerText
            $entry=ConvertFrom-Json -InputObject $_ -AsHashtable
            & ([scriptblock]::Create($worker)) $context $entry $runnerText $true
        } | ForEach-Object -ThrottleLimit $Concurrency -Parallel {
            if (-not $_.Succeeded) {$_;return}
            $context=$using:Context;$runnerText=$using:Runner;$worker=$using:workerText
            # Deserialize a private entry for the second worker's session and variables.
            $entry=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $_.Entry -Depth 20) -AsHashtable
            & ([scriptblock]::Create($worker)) $context $entry $runnerText $false
        }
    } else {
        $snapshots | ForEach-Object -ThrottleLimit $Concurrency -Parallel {
            $context=$using:Context;$runnerText=$using:Runner;$worker=$using:workerText
            $entry=ConvertFrom-Json -InputObject $_ -AsHashtable
            & ([scriptblock]::Create($worker)) $context $entry $runnerText $false
        }
    }
}
