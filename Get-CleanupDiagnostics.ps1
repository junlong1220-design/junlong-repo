#requires -Version 7.2
[CmdletBinding()]
param([string]$ConfigPath="$PSScriptRoot\init.json",[Parameter(Mandatory)][string]$StatePath,[string[]]$Names)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/lib/Aoc.ps1"
. "$PSScriptRoot/lib/Config.ps1"
. "$PSScriptRoot/lib/Credentials.ps1"
$script:Config=Get-Content -LiteralPath (Resolve-DeploymentFilePath $ConfigPath) -Raw | ConvertFrom-Json -AsHashtable
$stateFile=Resolve-DeploymentFilePath $StatePath
$state=Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json -AsHashtable
$receiptPath=[IO.Path]::ChangeExtension($stateFile,'.cleanup.json')
$receipt=$null
if (Test-Path -LiteralPath $receiptPath) {$receipt=Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -AsHashtable}
$script:AocBase=($Config.AocUrl.TrimEnd('/') -replace '/v2/api$','')+'/v2/api'
$script:AocToken='';$credentials=$null
try {
    $credentials=Set-InteractiveCredentials $Config @('Aoc')
    $login=Invoke-Aoc 'login' @{username=$Config.AocUsername;password=$credentials.Aoc.GetNetworkCredential().Password;source=$Config.AocUserSource}
    $script:AocToken=$login.data.token
    $cluster=Get-AocOne 'get-clusters' @{name=$Config.ClusterName}
    foreach ($entry in $state.Entries) {
        if ($Names -and $entry.Hostname -notin $Names) {continue}
        $row=$null
        if ($receipt) {$row=@($receipt.Entries | Where-Object VmId -EQ $entry.VmId) | Select-Object -First 1}
        $vms=@(Invoke-Aoc 'get-vms' @{where=@{id=$entry.VmId};first=2})
        $vm=$vms | Select-Object -First 1
        $actualCluster=Get-AocOptionalProperty (Get-AocOptionalProperty $vm 'cluster') 'id'
        [pscustomobject]@{
            ExpectedName=$entry.Hostname;ExpectedVmId=$entry.VmId;ExpectedTag=$entry.Tag;ExpectedClusterId=$cluster.id
            ResponseCount=$vms.Count;ActualId=(Get-AocOptionalProperty $vm 'id');ActualName=(Get-AocOptionalProperty $vm 'name')
            ActualDescription=(Get-AocOptionalProperty $vm 'description');ActualClusterId=$actualCluster
            InRecycleBin=(Get-AocOptionalProperty $vm 'in_recycle_bin');PowerStatus=(Get-AocOptionalProperty $vm 'status')
            CleanupPhase=(Get-AocOptionalProperty $row 'Phase');CleanupTaskId=(Get-AocOptionalProperty $row 'TaskId')
            CleanupError=(Get-AocOptionalProperty $row 'Error')
        } | Format-List | Out-Host
        $taskId=Get-AocOptionalProperty $row 'TaskId'
        if ($taskId) {
            foreach ($task in @(Invoke-Aoc 'get-tasks' @{where=@{id=$taskId};first=1})) {
                [pscustomobject]@{TaskId=$taskId;Status=(Get-AocOptionalProperty $task 'status');ResourceId=(Get-AocOptionalProperty $task 'resource_id')} | Format-List | Out-Host
            }
        }
    }
    Write-Host 'Read-only diagnostics completed. No VM, DNS or state changes were made.'
} finally {$script:AocToken='';Clear-InteractiveCredentials $Config $credentials}
