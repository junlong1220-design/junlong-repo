function Assert-HorizonUsername([string]$Username) {
    if ($Username -notmatch '^[^\\@\s"\r\n]+\\[^\\@\s"\r\n]+$') {
        throw 'HorizonUsername must use AD NetBIOS domain\username, not a UPN. Example: DEMO\administrator.'
    }
}
function Get-PublicConfigHash($Config,[switch]$IncludeDefaultIndexWidth) {
    $canonical=[ordered]@{}
    foreach ($key in @($Config.Keys | Sort-Object)) {
        if (-not $IncludeDefaultIndexWidth -and $key -eq 'IndexWidth' -and [string]$Config[$key] -eq '4') {continue}
        if ($key -eq 'FullCopy' -and $Config[$key] -is [bool] -and $Config[$key]) {continue}
        if ($key -notmatch 'Password$' -and $key -notin @('Concurrency','CloneConcurrency','TransferConcurrency','InstallConcurrency','FastPollSeconds','RebootTimeoutSeconds','TimeoutSeconds','InstallTimeoutSeconds','PollSeconds')) {$canonical[$key]=$Config[$key]}
    }
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($canonical | ConvertTo-Json -Depth 10 -Compress))))
}
function Test-HorizonUsernameMigration($Config,[string]$PreviousHash) {
    Assert-HorizonUsername $Config.HorizonUsername
    $candidate=$Config.Clone()
    $user=($Config.HorizonUsername -split '\\',2)[1]
    $candidate.HorizonUsername="$user@$($Config.DomainName)"
    (Get-PublicConfigHash $candidate) -eq $PreviousHash
}

function Resolve-DeploymentRuntimeSettings($Config,$Overrides) {
    $specifications=[ordered]@{
        TimeoutSeconds=@(900,60,7200)
        InstallTimeoutSeconds=@(1800,60,7200)
        PollSeconds=@(3,1,60)
        Concurrency=@(20,1,30)
        FastPollSeconds=@(3,1,30)
        RebootTimeoutSeconds=@(600,60,3600)
    }
    $settings=@{}
    foreach ($key in $specifications.Keys) {
        $spec=$specifications[$key];$value=$spec[0]
        if ($Overrides.ContainsKey($key)) {$value=$Overrides[$key]}
        elseif ($Config.ContainsKey($key)) {$value=$Config[$key]}
        if ($null -eq $value -or $value -is [bool] -or $value -is [string] -or $value -isnot [ValueType]) {
            throw "$key must be an integer from $($spec[1]) through $($spec[2])."
        }
        if ([double]$value -lt $spec[1] -or [double]$value -gt $spec[2] -or [Math]::Truncate([double]$value) -ne [double]$value) {
            throw "$key must be an integer from $($spec[1]) through $($spec[2])."
        }
        $settings[$key]=[int]$value
    }
    # One user setting feeds both independent pipeline pools.
    $settings.CloneConcurrency=$settings.Concurrency
    $settings
}

function Get-DeploymentFullCopy($Config) {
    if (-not $Config.ContainsKey('FullCopy')) {return $true}
    if ($Config.FullCopy -isnot [bool]) {throw 'FullCopy must be a JSON boolean: true or false.'}
    $Config.FullCopy
}

function Test-CloneModeMigration($Config,[string]$PreviousHash) {
    # Legacy batches always used full copy. An explicit false applies only to New entries.
    if (-not $Config.ContainsKey('FullCopy') -or $Config.FullCopy -isnot [bool] -or $Config.FullCopy) {return $false}
    $candidate=$Config.Clone();$candidate.Remove('FullCopy')
    (Get-PublicConfigHash $candidate) -eq $PreviousHash
}

function Get-LegacyPublicConfigHash($Config) {
    $canonical=[ordered]@{}
    foreach ($key in @($Config.Keys | Sort-Object)) {
        if ($key -notmatch 'Password$') {$canonical[$key]=$Config[$key]}
    }
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($canonical | ConvertTo-Json -Depth 10 -Compress))))
}
function Get-PreviousTimingConfigHash($Config) {
    $canonical=[ordered]@{}
    foreach ($key in @($Config.Keys | Sort-Object)) {
        if ($key -eq 'FullCopy' -and $Config[$key] -is [bool] -and $Config[$key]) {continue}
        if ($key -notmatch 'Password$' -and $key -notin @('Concurrency','CloneConcurrency','TransferConcurrency','InstallConcurrency','FastPollSeconds','RebootTimeoutSeconds')) {$canonical[$key]=$Config[$key]}
    }
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($canonical | ConvertTo-Json -Depth 10 -Compress))))
}
function Set-DeploymentTimingDefaults($Config) {
    $settings=Resolve-DeploymentRuntimeSettings $Config @{}
    foreach ($key in @('TimeoutSeconds','InstallTimeoutSeconds','PollSeconds')) {$Config[$key]=$settings[$key]}
}
function Get-ConfigCompatibilityReason($Config,[string]$PreviousHash) {
    if ((Get-PublicConfigHash $Config) -eq $PreviousHash) {return 'Current configuration matches.'}
    $variants=[Collections.Generic.List[object]]::new()
    $variants.Add(@{Config=$Config.Clone();Reason='Legacy hash format with identical configuration.'})
    if ($Config.ContainsKey('FullCopy') -and $Config.FullCopy -is [bool] -and -not $Config.FullCopy) {
        $candidate=$Config.Clone();$candidate.Remove('FullCopy')
        $variants.Add(@{Config=$candidate;Reason='Legacy full-copy to non-full-copy correction.'})
    }
    foreach ($variant in @($variants.ToArray())) {
        if (-not $variant.Config.ContainsKey('IndexWidth')) {
            $candidate=$variant.Config.Clone();$candidate.IndexWidth=4
            $variants.Add(@{Config=$candidate;Reason=($variant.Reason+' Built-in four-digit naming default.')})
        }
    }
    foreach ($variant in @($variants.ToArray())) {
        $candidate=$variant.Config.Clone();$candidate.TimeoutSeconds=1800;$candidate.InstallTimeoutSeconds=3600;$candidate.PollSeconds=10
        $variants.Add(@{Config=$candidate;Reason=($variant.Reason+' Previous built-in timing defaults.')})
    }
    foreach ($variant in @($variants.ToArray())) {
        if ($variant.Config.HorizonUsername -match '^[^\\@\s]+\\(?<User>[^\\@\s]+)$') {
            $candidate=$variant.Config.Clone()
            $candidate.HorizonUsername="$($Matches.User)@$($candidate.DomainName)"
            $variants.Add(@{Config=$candidate;Reason=($variant.Reason+' Same-user Horizon UPN format correction.')})
        }
    }
    foreach ($variant in $variants) {
        if ((Get-PublicConfigHash $variant.Config) -eq $PreviousHash -or (Get-LegacyPublicConfigHash $variant.Config) -eq $PreviousHash -or (Get-PreviousTimingConfigHash $variant.Config) -eq $PreviousHash -or (Get-PublicConfigHash $variant.Config -IncludeDefaultIndexWidth) -eq $PreviousHash) {return $variant.Reason}
    }
    return ''
}

function Resolve-DeploymentFilePath([string]$Path) {
    # Resolve against PowerShell's provider location, not the process working directory.
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Assert-BatchConfigReconciliation($State,[string[]]$Names) {
    # Existing guest stages only: reconciliation never creates or reissues clone tasks.
    $allowed=@('Renamed','JoinPending','Joined','Installing','AgentRebootPending','Installed','Verified')
    if ($State.Entries.Count -ne $Names.Count) {throw 'Reconciliation requires the same VM count as the saved batch.'}
    $saved=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $State.Entries) {
        if (-not $entry.VmId -or -not $entry.Tag -or $entry.Phase -notin $allowed) {
            throw "Cannot reconcile $($entry.Hostname) at phase $($entry.Phase). Only existing VMs at Renamed or later guest stages are eligible."
        }
        if (-not $saved.Add([string]$entry.Hostname)) {throw 'Duplicate names in saved state.'}
    }
    foreach ($name in $Names) {if (-not $saved.Contains($name)) {throw 'Reconciliation cannot change saved VM names.'}}
}
