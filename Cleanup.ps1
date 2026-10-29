#requires -Version 7.2
[CmdletBinding()]
param([string]$ConfigPath="$PSScriptRoot\init.json",[Parameter(Mandatory)][string]$StatePath,[string[]]$Names,[switch]$Execute,[ValidateRange(1,30)][int]$Concurrency=20)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/lib/Aoc.ps1"
. "$PSScriptRoot/lib/Config.ps1"
. "$PSScriptRoot/lib/Credentials.ps1"
. "$PSScriptRoot/lib/Cleanup.ps1"
if (-not $IsWindows) {throw 'Run cleanup on the Windows controller with PowerShell 7.2+.'}
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {throw 'Run elevated PowerShell on the Windows controller.'}
$stateFile=Resolve-DeploymentFilePath $StatePath
$Config=Get-Content -LiteralPath (Resolve-DeploymentFilePath $ConfigPath) -Raw | ConvertFrom-Json -AsHashtable
Set-DeploymentTimingDefaults $Config
$script:AocToken='';$script:AocBase=($Config.AocUrl.TrimEnd('/') -replace '/v2/api$','')+'/v2/api'
$cleanupFile=[IO.Path]::ChangeExtension($stateFile,'.cleanup.json')
$script:CleanupParallelContext=$null
$interactiveCredentials=$null
$lock=$null;$session=$null;$trustedOriginal=$null;$trustedChanged=$false
function Save-Cleanup {
    if ($script:CleanupParallelContext) {
        Save-ParallelCleanupRow $script:CleanupParallelContext $script:CleanupWorkerRow
    } else {Write-CleanupReceipt -Path $cleanupFile -Receipt $receipt}
}
function Complete-CleanupAction($row,[string]$Action,[string]$Endpoint) {
    $pending="$($Action)Pending"
    if ($row.Phase -ne $pending) {
        $row.Phase=$pending;$row.TaskId='';Save-Cleanup
        $response=@(Invoke-Aoc $Endpoint @{where=@{id=$row.VmId}})
        if ($response.Count -ne 1) {throw 'Unexpected AOC operation response. Inspect task center before resuming.'}
        $row.TaskId=[string](Get-AocOptionalProperty $response[0] 'task_id');Save-Cleanup
    }
    if (-not $row.TaskId) {throw "Uncertain $Action submission for $($row.Hostname). Inspect AOC task center; automatic resubmission is blocked."}
    Wait-AocTask $row.TaskId
}
function Invoke-CleanupVm($entry,$row) {
        try {
            Write-Host "[$(Get-Date -Format HH:mm:ss)] $($entry.Hostname): cleanup phase=$($row.Phase)"
            $vm=Get-AocVm $entry.VmId;Assert-CleanupVm $entry $vm $cluster.id
            if ($vm.in_recycle_bin) {$row.Phase='Recycled';$row.TaskId='';Save-Cleanup}
            elseif ($row.Phase -in @('Recycled','Completed')) {throw 'Previously recycled VM has been restored. Cleanup stopped for this VM.'}
            else {
                if ($row.Phase -ne 'RecyclePending') {
                    if ($vm.status -ne 'STOPPED') {Complete-CleanupAction $row 'PowerOff' 'poweroff-vm'}
                    $vm=Get-AocVm $entry.VmId;Assert-CleanupVm $entry $vm $cluster.id
                    if ($vm.status -ne 'STOPPED') {throw 'VM is not stopped after power off.'}
                    $row.Phase='Stopped';$row.TaskId='';Save-Cleanup
                }
                Complete-CleanupAction $row 'Recycle' 'move-vm-to-recycle'
                $vm=Get-AocVm $entry.VmId;Assert-CleanupVm $entry $vm $cluster.id
                if (-not $vm.in_recycle_bin) {throw 'AOC did not confirm the VM is in the recycle bin.'}
                $row.Phase='Recycled';$row.TaskId='';Save-Cleanup
            }
            return [pscustomobject]@{Hostname=$entry.Hostname;VmId=$entry.VmId;Succeeded=$true}
        } catch {
            $message=$_.Exception.Message
            foreach ($secret in @(Get-AocRequestSecrets $Config;foreach ($cred in $interactiveCredentials.Values) {$cred.GetNetworkCredential().Password})) {if ($secret) {$message=$message.Replace($secret,'[REDACTED]')}}
            $row.Error=$message;try {Save-Cleanup} catch {$message+=" State save also failed: $($_.Exception.Message)"};Write-Warning "$($entry.Hostname): $message"
            return [pscustomobject]@{Hostname=$entry.Hostname;VmId=$entry.VmId;Succeeded=$false}
        }
}

try {
    $runtime=Resolve-DeploymentRuntimeSettings $Config $PSBoundParameters
    $Concurrency=$runtime.Concurrency
    $interactiveCredentials=Set-InteractiveCredentials $Config @('Aoc','Domain')
    $lock=[IO.File]::Open("$stateFile.lock",'OpenOrCreate','ReadWrite','None')
    $state=Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    $entries=@($state.Entries)
    if ($Names) {
        foreach ($name in $Names) {if ($name -notin $entries.Hostname) {throw "Name is not recorded in this batch: $name"}}
        $entries=@($entries | Where-Object Hostname -In $Names)
    }
    if (-not $entries.Count -or @($entries.Hostname | Select-Object -Unique).Count -ne $entries.Count) {throw 'Empty or duplicate cleanup selection.'}
    foreach ($entry in $entries) {if (-not $entry.VmId -or -not $entry.Tag -or $entry.Hostname -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$') {throw 'Every selected entry must have a saved VM ID, ownership tag and valid hostname.'}}
    $snapshot=Get-AocOptionalProperty $state 'PublicConfig'
    if ($snapshot -and (Get-AocOptionalProperty $snapshot 'DomainName') -and $snapshot.DomainName -ine $Config.DomainName) {throw 'DNS domain differs from the saved deployment configuration.'}
    if (Test-Path -LiteralPath $cleanupFile) {
        $receipt=Get-Content -LiteralPath $cleanupFile -Raw | ConvertFrom-Json
        if ($receipt.StateFile -ne $stateFile -or $receipt.DomainName -ine $Config.DomainName -or $receipt.AocUrl -ine $Config.AocUrl) {throw 'Cleanup receipt target configuration changed.'}
    } else {$receipt=[pscustomobject]@{StateFile=$stateFile;DomainName=$Config.DomainName;AocUrl=$Config.AocUrl;Entries=@()}}
    foreach ($entry in $entries) {
        $rows=@($receipt.Entries | Where-Object VmId -EQ $entry.VmId)
        if (-not $rows.Count) {$receipt.Entries+= [pscustomobject]@{VmId=$entry.VmId;Hostname=$entry.Hostname;Tag=$entry.Tag;Phase='New';TaskId='';Error=''}}
        elseif ($rows.Count -ne 1 -or $rows[0].Hostname -ine $entry.Hostname -or $rows[0].Tag -cne $entry.Tag) {throw 'Cleanup receipt ownership mismatch.'}
    }
    $login=Invoke-Aoc 'login' @{username=$Config.AocUsername;password=$interactiveCredentials.Aoc.GetNetworkCredential().Password;source=$Config.AocUserSource}
    $script:AocToken=$login.data.token
    $cluster=Get-AocOne 'get-clusters' @{name=$Config.ClusterName}
    # Verify the entire selection before changing any VM.
    foreach ($entry in $entries) {Assert-CleanupVm $entry (Get-AocVm $entry.VmId) $cluster.id}
    $credential=$interactiveCredentials.Domain
    $trustedOriginal=[string](Get-Item WSMan:\localhost\Client\TrustedHosts).Value
    if ($Config.DomainControllerIP -notin ($trustedOriginal -split ',')) {
        Set-Item WSMan:\localhost\Client\TrustedHosts -Value ((@($trustedOriginal,$Config.DomainControllerIP) | Where-Object {$_}) -join ',') -Force
        $trustedChanged=$true
    }
    $session=New-PSSession -ComputerName $Config.DomainControllerIP -Authentication Negotiate -Credential $credential
    $plan=@(Invoke-Command -Session $session -ScriptBlock $script:CleanupDnsRecords -ArgumentList $Config.DomainName,([string[]]$entries.Hostname),$false)
    $entries | Select-Object Hostname,VmId | Format-Table | Out-Host
    $plan | Format-Table VM,Zone,Owner,Type | Out-Host
    if (-not $Execute) {Write-Host 'Preview only. Add -Execute to force power off, recycle these VMs and delete their A/AAAA/PTR DNS records.';return}
    Save-Cleanup
    Write-Host "Cleanup concurrency: $Concurrency. Poweroff/recycle workflows run in parallel; DNS uses the existing server session."
    $work=@(foreach ($entry in $entries) {
        $row=$receipt.Entries | Where-Object VmId -EQ $entry.VmId
        [pscustomobject]@{Entry=$entry;Row=$row}
    })
    if ($Concurrency -eq 1) {
        $results=@(foreach ($item in $work) {Invoke-CleanupVm $item.Entry $item.Row})
    } else {
        $definitions=@('Save-Cleanup','Complete-CleanupAction','Invoke-CleanupVm') | ForEach-Object {"function $_ {`n$((Get-Command $_ -CommandType Function).Definition)`n}"}
        $definitionText=$definitions -join "`n"
        $context=@{Root=$PSScriptRoot;Config=$Config;AocBase=$script:AocBase;AocToken=$script:AocToken;Cluster=$cluster;Credentials=$interactiveCredentials;Receipt=$receipt;ReceiptPath=$cleanupFile;Gate=[object]::new()}
        $snapshots=@($work | ForEach-Object {ConvertTo-Json -InputObject $_ -Depth 20 -Compress})
        $results=@($snapshots | ForEach-Object -ThrottleLimit $Concurrency -Parallel {
            $ErrorActionPreference='Stop';Set-StrictMode -Version Latest
            $context=$using:context
            foreach ($library in @('Aoc','Cleanup')) {. (Join-Path $context.Root "lib/$library.ps1")}
            Invoke-Expression $using:definitionText
            $script:Config=$context.Config;$script:AocBase=$context.AocBase;$script:AocToken=$context.AocToken
            $cluster=$context.Cluster;$interactiveCredentials=$context.Credentials
            $script:CleanupParallelContext=$context
            $item=ConvertFrom-Json -InputObject $_ -AsHashtable
            $script:CleanupWorkerRow=$item.Row
            Invoke-CleanupVm $item.Entry $item.Row
        })
    }
    $failed=@($results | Where-Object {-not $_.Succeeded}).Count
    # Keep DNS writes on one authenticated session. A failed VM never reaches DNS deletion.
    foreach ($result in @($results | Where-Object Succeeded)) {
        $row=$receipt.Entries | Where-Object VmId -EQ $result.VmId
        try {
            $vm=Get-AocVm $row.VmId
            Assert-CleanupVm $row $vm $cluster.id
            if (-not $vm.in_recycle_bin) {throw 'VM is no longer in the recycle bin; DNS deletion was blocked.'}
            $null=Invoke-Command -Session $session -ScriptBlock $script:CleanupDnsRecords -ArgumentList $Config.DomainName,([string[]]@($row.Hostname)),$true
            $remaining=@(Invoke-Command -Session $session -ScriptBlock $script:CleanupDnsRecords -ArgumentList $Config.DomainName,([string[]]@($row.Hostname)),$false)
            if ($remaining.Count) {throw 'Matching DNS records remain after deletion.'}
            $row.Phase='Completed';$row.Error='';Save-Cleanup
            Write-Host "$($row.Hostname): recycled; matching DNS records removed."
        } catch {
            $failed++;$message=$_.Exception.Message
            foreach ($redactionCredential in $interactiveCredentials.Values) {$message=$message.Replace($redactionCredential.GetNetworkCredential().Password,'[REDACTED]')}
            $row.Error=$message;Save-Cleanup;Write-Warning "$($row.Hostname): $message"
        }
    }
    Write-Host "Cleanup receipt: $cleanupFile"
    if ($failed) {throw "$failed VM(s) did not finish cleanup. Rerun the same command after correcting the reported cause."}
} finally {
    if ($session) {Remove-PSSession $session}
    if ($trustedChanged) {Set-Item WSMan:\localhost\Client\TrustedHosts -Value $trustedOriginal -Force}
    if ($lock) {$lock.Dispose()}
    $script:AocToken=''
    Clear-InteractiveCredentials $Config $interactiveCredentials
    $credential=$null
}
