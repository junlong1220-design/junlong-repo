#requires -Version 7.2
[CmdletBinding()]
param([string]$ConfigPath="$PSScriptRoot\init.json",[Parameter(Mandatory)][string]$StatePath,[ValidateRange(1,100)][int]$Limit=3)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/lib/Aoc.ps1"
. "$PSScriptRoot/lib/Config.ps1"
. "$PSScriptRoot/lib/Credentials.ps1"
$ConfigPath=Resolve-DeploymentFilePath $ConfigPath
$StatePath=Resolve-DeploymentFilePath $StatePath
Write-Host "Resolved batch state: $StatePath"
$script:Config=Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
Set-DeploymentTimingDefaults $Config
$script:AocBase=($Config.AocUrl.TrimEnd('/') -replace '/v2/api$','')+'/v2/api'
$script:AocToken=''
$interactiveCredentials=$null
try {
    $interactiveCredentials=Set-InteractiveCredentials $Config @('Aoc')
    $login=Invoke-Aoc 'login' @{username=$Config.AocUsername;password=$interactiveCredentials.Aoc.GetNetworkCredential().Password;source=$Config.AocUserSource}
    $script:AocToken=$login.data.token
    $state=Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json -AsHashtable
    foreach ($entry in @($state.Entries | Where-Object {$_.TaskId} | Select-Object -First $Limit)) {
        Write-Output "=== $($entry.Hostname): phase=$($entry.Phase); saved task=$($entry.TaskId) ==="
        $tasks=@(Invoke-Aoc 'get-tasks' @{where=@{id=$entry.TaskId};first=2})
        Write-Output "Task response count: $($tasks.Count)"
        foreach ($task in $tasks) {
            $summary=[ordered]@{}
            foreach ($key in @('id','status','progress','started_at','finished_at','resource_id','resource_type','error_code')) {
                $summary[$key]=Get-AocOptionalProperty $task $key
            }
            $summary | ConvertTo-Json -Depth 4
            Write-Output ('Response property names: '+(($task.PSObject.Properties.Name) -join ', '))
        }
        if ($entry.VmId) {
            $vm=Get-AocVm $entry.VmId
            [ordered]@{VmId=$vm.id;Name=$vm.name;PowerStatus=$vm.status;IPs=(Get-AocOptionalProperty $vm 'ips');OwnershipTagMatches=((Get-AocOptionalProperty $vm 'description') -eq $entry.Tag)} | ConvertTo-Json
        }
    }
} finally {$script:AocToken='';Clear-InteractiveCredentials $Config $interactiveCredentials}
