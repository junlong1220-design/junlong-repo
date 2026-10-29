function Enter-DeploymentGate($Gate) {
    if ($Gate) {$Gate.Wait() | Out-Null}
}
function Exit-DeploymentGate($Gate) {
    if ($Gate) {$Gate.Release() | Out-Null}
}
function Test-GuestTcpPort([string]$Address,[int]$Port=5985,[int]$TimeoutMilliseconds=1000) {
    $client=[Net.Sockets.TcpClient]::new()
    try {
        $task=$client.ConnectAsync($Address,$Port)
        if (-not $task.Wait($TimeoutMilliseconds)) {return $false}
        $task.GetAwaiter().GetResult()
        $client.Connected
    } catch {return $false} finally {$client.Dispose()}
}
function Update-PhaseTiming($Entry,[string]$NextPhase) {
    $now=[datetime]::UtcNow
    if (-not $Entry.ContainsKey('PhaseSeconds')) {$Entry.PhaseSeconds=@{}}
    if ($Entry.ContainsKey('PhaseEnteredUtc') -and $Entry.PhaseEnteredUtc) {
        $elapsed=[Math]::Max(0,($now-[datetime]::Parse($Entry.PhaseEnteredUtc).ToUniversalTime()).TotalSeconds)
        $previous=[string]$Entry.Phase
        $total=0.0
        if ($Entry.PhaseSeconds.ContainsKey($previous)) {$total=[double]$Entry.PhaseSeconds[$previous]}
        $Entry.PhaseSeconds[$previous]=[Math]::Round($total+$elapsed,1)
    }
    $Entry.PhaseEnteredUtc=$now.ToString('o')
}
