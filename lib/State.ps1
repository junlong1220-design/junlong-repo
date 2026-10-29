function Write-DeploymentStateFile {
    param([string]$Path,$Value)
    # Only local persistence is retried. Callers serialize concurrent saves with
    # their existing batch lock/monitor; remote operations are never repeated here.
    $temporary="$Path.tmp-$([guid]::NewGuid().ToString('N'))"
    $json=ConvertTo-Json -InputObject $Value -Depth 20
    $snapshotReady=$false
    for ($attempt=1;$attempt -le 20;$attempt++) {
        try {
            if (-not $snapshotReady) {
                [IO.File]::WriteAllText($temporary,$json,[Text.UTF8Encoding]::new($false))
                $snapshotReady=$true
            }
            if ([IO.File]::Exists($Path)) {[IO.File]::Replace($temporary,$Path,[System.Management.Automation.Language.NullString]::Value)}
            else {[IO.File]::Move($temporary,$Path)}
            return
        } catch {
            $cause=$_.Exception
            while ($cause.InnerException) {$cause=$cause.InnerException}
            if (($cause -isnot [IO.IOException] -and $cause -isnot [UnauthorizedAccessException]) -or $attempt -eq 20) {
                throw "State file save failed: '$Path'. Check permissions, read-only attributes and file locks. Uncommitted snapshot: '$temporary'. No remote operation was retried. Cause: $($cause.Message)"
            }
            Start-Sleep -Milliseconds 250
        }
    }
}
