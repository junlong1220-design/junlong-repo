Set-StrictMode -Version Latest

function Get-AocRequestSecrets {
    param([object]$Value)
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            if ([string]$key -match '(?i)password|token|secret') {
                if ($Value[$key]) { [string]$Value[$key] }
            } else { Get-AocRequestSecrets $Value[$key] }
        }
    } elseif ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        foreach ($item in $Value) { Get-AocRequestSecrets $item }
    }
}

function Write-AocResponseItems {
    [CmdletBinding()]
    param([AllowNull()][object]$Value,[int]$Depth=0)
    if ($null -eq $Value) {return}
    if ($Depth -gt 12) {throw 'AOC response collection nesting exceeded the supported depth.'}
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [Collections.IDictionary] -and $Value -isnot [string]) {
        foreach ($item in $Value) {Write-AocResponseItems -Value $item -Depth ($Depth+1)}
    } else {
        # Write-Output -NoEnumerate can wrap a scalar in List[object] on PowerShell 7.
        # Emit the scalar directly without adding a collection wrapper.
        $PSCmdlet.WriteObject($Value,$false)
    }
}

function Invoke-Aoc {
    param([string]$Path, [object]$Body)
    $request = @{
        Uri = "$script:AocBase/$Path"; Method = 'Post'; ContentType = 'application/json'
        Body = (ConvertTo-Json -InputObject $Body -Depth 40 -Compress)
        TimeoutSec = 120; ErrorAction = 'Stop'
    }
    if ($script:AocToken) { $request.Headers = @{ Authorization = $script:AocToken } }
    if ($script:Config.SkipAocCertificateCheck) { $request.SkipCertificateCheck = $true }
    try {
        $response=Invoke-RestMethod @request
        Write-AocResponseItems -Value $response
    }
    catch {
        $errorRecord=$_
        $status='unavailable'
        $responseProperty=$errorRecord.Exception.PSObject.Properties['Response']
        if ($responseProperty -and $responseProperty.Value) {
            $statusProperty=$responseProperty.Value.PSObject.Properties['StatusCode']
            if ($statusProperty -and $null -ne $statusProperty.Value) { $status=[int]$statusProperty.Value }
        }
        $reasons=@();$exception=$errorRecord.Exception
        while ($exception -and $reasons.Count -lt 4) {
            $reasons+="$($exception.GetType().Name): $($exception.Message)"
            $exception=$exception.InnerException
        }
        $diagnostic=$reasons -join ' | '
        foreach ($secret in @((Get-AocRequestSecrets $Body),$script:AocToken) | ForEach-Object { $_ } | Where-Object { $_ }) {
            $diagnostic=$diagnostic.Replace([string]$secret,'[REDACTED]')
            $diagnostic=$diagnostic.Replace([Uri]::EscapeDataString([string]$secret),'[REDACTED]')
        }
        $diagnostic=($diagnostic -replace '[\r\n]+',' ')
        if ($diagnostic.Length -gt 700) { $diagnostic=$diagnostic.Substring(0,700) }
        # Do not output ErrorDetails/response body, headers, request body or token.
        throw "AOC $Path failed. HTTP status: $status. $diagnostic Request was not automatically retried."
    }
}

function Get-AocOptionalProperty {
    param([object]$Value,[string]$Name)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Contains($Name)) { return $Value[$Name] }
        return $null
    }
    $property=$Value.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-AocOne {
    param([string]$Path, [hashtable]$Where)
    $items = @(Invoke-Aoc $Path @{where=$Where; first=2})
    if ($items.Count -ne 1) { throw "${Path}: expected one matching resource; found $($items.Count)." }
    return $items[0]
}

function Wait-AocTask {
    param([string]$TaskId)
    if (-not $TaskId) { throw 'AOC returned no task_id; reconcile the operation in AOC before continuing.' }
    $deadline = [datetime]::UtcNow.AddSeconds($script:Config.TimeoutSeconds)
    $taskWatch=[Diagnostics.Stopwatch]::StartNew();$nextNotice=[datetime]::MinValue;$lastStatus='not returned';$lastCount=0;$lastProgress=$null
    do {
        $tasks = @(Invoke-Aoc 'get-tasks' @{where=@{id=$TaskId};first=1})
        $lastCount=$tasks.Count
        if ($tasks.Count -eq 1) {
            $lastStatus=[string](Get-AocOptionalProperty $tasks[0] 'status')
            $lastProgress=Get-AocOptionalProperty $tasks[0] 'progress'
            switch ($tasks[0].status) {
                'SUCCESSED' {Write-Host "AOC task $TaskId completed after $([Math]::Round($taskWatch.Elapsed.TotalSeconds,1)) seconds of monitoring.";return}
                'FAILED' { throw "AOC task $TaskId failed. Inspect task center for details." }
                'PAUSED' { throw "AOC task $TaskId is paused. Resolve in AOC and resume." }
                'PENDING' { }
                'EXECUTING' { }
                default {throw "AOC task $TaskId returned an unrecognized status '$lastStatus'. Run Get-AocTaskDiagnostics.ps1; success was not assumed."}
            }
        }
        if ([datetime]::UtcNow -ge $nextNotice) {
            $status='not returned'
            if ($tasks.Count -eq 1) {$status=$tasks[0].status}
            Write-Host "AOC task ${TaskId}: status=$status; progress=$lastProgress; monitoring=$([Math]::Round($taskWatch.Elapsed.TotalSeconds)) seconds."
            $nextNotice=[datetime]::UtcNow.AddSeconds(30)
        }
        $interval=$script:Config.PollSeconds
        $runtime=Get-Variable RuntimePollSeconds -Scope Script -ErrorAction SilentlyContinue
        if ($runtime) {$interval=$runtime.Value}
        Start-Sleep -Seconds $interval
    } while ([datetime]::UtcNow -lt $deadline)
    throw "AOC task $TaskId timed out; last status=$lastStatus; progress=$lastProgress; response count=$lastCount. Saved task will be checked on the next run; creation was not resubmitted."
}

function Get-AocVm {
    param([string]$VmId)
    Get-AocOne 'get-vms' @{id=$VmId}
}

function Get-GuestIPs {
    param([object]$Vm)
    # Vm.ips is a string in the published specification. Do NOT use node_ip (hypervisor IP).
    $matches = [regex]::Matches([string]$Vm.ips, '(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])')
    @($matches | ForEach-Object {
        $ip = $null
        if ([System.Net.IPAddress]::TryParse($_.Value, [ref]$ip) -and
            $ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
            $_.Value -notmatch '^(127\.|169\.254\.|0\.)') { $_.Value }
    } | Select-Object -Unique)
}


function Confirm-AocVmStarted {
    param($Entry,[string]$ClusterId)
    # Recover an observed power-on without resubmitting an uncertain start request.
    $vm=Get-AocVm $Entry.VmId
    foreach ($pass in 1..2) {
        $vmCluster=Get-AocOptionalProperty (Get-AocOptionalProperty $vm 'cluster') 'id'
        if (-not $Entry.VmId -or -not $Entry.Tag -or $vm.id -ne $Entry.VmId -or
            $vm.name -ine $Entry.Hostname -or $vm.description -cne $Entry.Tag -or
            $vmCluster -ne $ClusterId -or (Get-AocOptionalProperty $vm 'in_recycle_bin')) {
            throw 'VM identity mismatch while recovering the Starting phase.'
        }
        if ($vm.status -eq 'RUNNING') {
            Write-Host "$($Entry.Hostname): AOC confirms the owned VM is RUNNING; continuing without resubmitting power on."
            return
        }
        if ($pass -eq 1 -and $Entry.TaskId) {Wait-AocTask $Entry.TaskId;$vm=Get-AocVm $Entry.VmId;continue}
        throw "Start result uncertain: $($Entry.Hostname) is '$($vm.status)'. Inspect AOC task center; if no start task is active, power on this VM manually and rerun with the same state. No start request was resubmitted."
    }
}
