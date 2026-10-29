#requires -Version 7.2
[CmdletBinding()]
param([string]$ConfigPath="$PSScriptRoot\init.json",[string]$StatePath="$PSScriptRoot\state.json",[switch]$ValidateOnly,[switch]$ReconcileConfig,[ValidateRange(1,30)][int]$Concurrency=20,[ValidateRange(1,30)][int]$FastPollSeconds=3,[ValidateRange(60,3600)][int]$RebootTimeoutSeconds=600)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/lib/Aoc.ps1"
. "$PSScriptRoot/lib/Agent.ps1"
. "$PSScriptRoot/lib/Naming.ps1"
. "$PSScriptRoot/lib/Rename.ps1"
. "$PSScriptRoot/lib/GuestCredentials.ps1"
. "$PSScriptRoot/lib/Config.ps1"
. "$PSScriptRoot/lib/Credentials.ps1"
. "$PSScriptRoot/lib/Firewall.ps1"
. "$PSScriptRoot/lib/Parallel.ps1"
. "$PSScriptRoot/lib/Performance.ps1"
$script:ParallelContext=$null
$script:ProvisionOnly=$false
$script:CloneGate=$null
$script:RuntimePollSeconds=$FastPollSeconds
$script:RuntimeRebootTimeout=$RebootTimeoutSeconds
function New-DeploymentCredential([string]$User,[string]$PlainTextSecret) { [pscredential]::new($User,(ConvertTo-SecureString $PlainTextSecret -AsPlainText -Force)) }
function Save-State {
    if ($script:ParallelContext) {
        Save-ParallelEntry $script:ParallelContext $script:WorkerEntry
    } else {
        Write-DeploymentStateFile -Path $script:StateFile -Value $script:State
    }
}
function Phase($Entry,[string]$Name) { Update-PhaseTiming $Entry $Name;$Entry.Phase=$Name;$Entry.Error='';Save-State;Write-Host "[$(Get-Date -Format HH:mm:ss)] $($Entry.Hostname): $Name" }
$script:Identity={
    $cs=Get-CimInstance Win32_ComputerSystem
    [pscustomobject]@{Name=$env:COMPUTERNAME;Domain=$cs.Domain;Joined=$cs.PartOfDomain;UUID=(Get-CimInstance Win32_ComputerSystemProduct).UUID;Boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')}
}
function Connect-Guest($Entry,[pscredential]$Cred,[string]$AfterBoot='') {
    $waitSeconds=[int]$Config.TimeoutSeconds
    if ($Entry.Phase -in @('RenamePending','JoinPending','AgentRebootPending')) {$waitSeconds=[Math]::Min($waitSeconds,$script:RuntimeRebootTimeout)}
    $deadline=[datetime]::UtcNow.AddSeconds($waitSeconds);$nextNotice=[datetime]::MinValue;$lastReason='No usable VMTools IP reported yet.'
    do {
        $vm=Get-AocVm $Entry.VmId
        $candidates=@(@($Entry.IP)+@(Get-GuestIPs $vm) | Where-Object {$_} | Select-Object -Unique)
        foreach ($ip in $candidates) {
            if (-not (Test-GuestTcpPort $ip)) {$lastReason="TCP 5985 is not reachable at $ip.";continue}
            $session=$null
            try {
                if ($script:ParallelContext) {[Threading.Monitor]::Enter($script:ParallelContext.Gate)}
                try {
                    $trusted=@(([string](Get-Item WSMan:\localhost\Client\TrustedHosts).Value -split ',') | Where-Object {$_})
                    if ($ip -notin $trusted) {Set-Item WSMan:\localhost\Client\TrustedHosts -Value (($trusted+$ip | Select-Object -Unique) -join ',') -Force}
                } finally {if ($script:ParallelContext) {[Threading.Monitor]::Exit($script:ParallelContext.Gate)}}
                $users=@(Get-GuestCredentialUsernames $Entry $Cred.UserName $ip ($Cred -eq $local))
                $connectError=$null
                foreach ($user in $users) {
                    try {
                        $session=New-PSSession -ComputerName $ip -Authentication Negotiate -Credential (New-DeploymentCredential $user $Cred.GetNetworkCredential().Password) -SessionOption (New-PSSessionOption -MaxConnectionRetryCount 0 -OpenTimeout 10000 -OperationTimeout (($Config.InstallTimeoutSeconds+120)*1000)) -ErrorAction Stop
                        break
                    } catch {$connectError=$_}
                }
                if (-not $session) {throw "WinRM authentication/connection failed at $ip. Tried usernames: $($users -join ' , '). $($connectError.Exception.Message)"}
                $identity=Invoke-Command -Session $session -ScriptBlock $script:Identity
                if ($identity.UUID -ine $vm.bios_uuid) { throw 'VM identity mismatch.' }
                $Entry.GuestComputerName=$identity.Name
                if ($Entry.Phase -eq 'RenamePending') {
                    $renameError=Invoke-Command -Session $session -ScriptBlock {
                        $path='C:\ProgramData\SimpleVDI\rename-result.json'
                        if (Test-Path $path) {$r=Get-Content $path -Raw | ConvertFrom-Json;if ($r.Status -eq 'Failed') {$r.Error}}
                    }
                    if ($renameError) {
                        Remove-PSSession $session;$session=$null
                        throw [InvalidOperationException]::new("Rename task failed: $renameError")
                    }
                }
                if ($AfterBoot -and $identity.Boot -eq $AfterBoot) { $lastReason='WinRM is reachable, but Windows still reports the pre-reboot boot time.';Remove-PSSession $session;$session=$null;continue }
                $Entry.IP=$ip;Save-State
                return $session
            } catch {
                $lastReason=($_.Exception.Message -split '[\r\n]')[0]
                foreach ($secret in @(Get-AocRequestSecrets $Config;foreach ($redactionCredential in @($local,$ad,$horizon)) {if ($redactionCredential) {$redactionCredential.GetNetworkCredential().Password}})) {if ($secret) {$lastReason=$lastReason.Replace($secret,'[REDACTED]')}}
                if ($_.Exception -is [InvalidOperationException] -and $_.Exception.Message.StartsWith('Rename task failed:')) {throw}; if ($session) { Remove-PSSession $session -ErrorAction SilentlyContinue } }
        }
        if ([datetime]::UtcNow -ge $nextNotice) { Write-Host "$($Entry.Hostname): waiting for DHCP / VMTools IP / WinRM / reboot ($($Entry.Phase)); last check: $lastReason";$nextNotice=[datetime]::UtcNow.AddSeconds(30) }
        Start-Sleep -Seconds $script:RuntimePollSeconds
    } while ([datetime]::UtcNow -lt $deadline)
    throw "Guest connection timed out. Last check: $lastReason"
}
function Restart-GuestAndWait($Entry,[pscredential]$Cred) {
    $s=Connect-Guest $Entry $Cred
    try {
        $identity=Invoke-Command -Session $s -ScriptBlock $script:Identity
        if ($identity.Boot -eq $Entry.PreviousBoot) {
            Invoke-Command -Session $s -ScriptBlock { & shutdown.exe /r /t 10 /f | Out-Null;if ($LASTEXITCODE -ne 0) {throw 'Reboot scheduling failed.'} }
        }
    } finally { Remove-PSSession $s }
    $s=Connect-Guest $Entry $Cred $Entry.PreviousBoot
    Remove-PSSession $s
}
function Invoke-EntryDeployment($entry) {
    $session=$null;$success=$true
        try {
            Write-Host "$($entry.Hostname): worker started at phase $($entry.Phase)."
            if ($entry.Phase -in @('New','CreateSubmitted')) {
                Write-Host "$($entry.Hostname): waiting for a clone slot."
                $queueWatch=[Diagnostics.Stopwatch]::StartNew()
                Enter-DeploymentGate $script:CloneGate
                try {
                    $entry.CloneQueueSeconds=[Math]::Round($queueWatch.Elapsed.TotalSeconds,1);Save-State
                    Write-Host "$($entry.Hostname): clone slot acquired after $($entry.CloneQueueSeconds) seconds."
            if ($entry.Phase -eq 'New') {
                $body=@{template_id=$template.id;cluster_id=$cluster.id;name=$entry.Hostname;description=$entry.Tag;is_full_copy=(Get-DeploymentFullCopy $Config);status='STOPPED';vcpu=[int]$Config.CpuCount;memory=[long]$Config.MemoryGB;memory_unit='GB'}
                # No cloud_init and no vm_nics override: use the prepared template's guest and network settings.
                $entry.CloneFullCopy=$body.is_full_copy
                Write-Host "$($entry.Hostname): submitting clone with is_full_copy=$($body.is_full_copy)."
                Phase $entry 'CreateSubmitted'
                $response=@(Invoke-Aoc 'create-vm-from-content-library-template' @($body))
                if ($response.Count -ne 1) {throw 'Unexpected create response; reconcile in AOC.'}
                $entry.VmId=$response[0].data.id;$entry.TaskId=$response[0].task_id;Save-State
            }
            if ($entry.Phase -eq 'CreateSubmitted') {
                if (-not $entry.VmId -or -not $entry.TaskId) {throw 'Create result uncertain. Reconcile VM/task in AOC; do not blindly resubmit.'}
                Wait-AocTask $entry.TaskId;Phase $entry 'Created'
            }
                } finally {Exit-DeploymentGate $script:CloneGate}
            }
            if ($entry.Phase -eq 'Created') {
                $vm=Get-AocVm $entry.VmId
                if ($vm.status -eq 'STOPPED') {
                    $entry.TaskId='';Phase $entry 'Starting'
                    $started=@(Invoke-Aoc 'start-vm' @{where=@{id=$entry.VmId}})
                    if ($started.Count -ne 1) {throw 'Unexpected start response.'}
                    $entry.TaskId=$started[0].task_id;Save-State
                } elseif ($vm.status -eq 'RUNNING') {Phase $entry 'Started'} else {throw 'Unexpected VM power status.'}
            }
            if ($entry.Phase -eq 'Starting') {Confirm-AocVmStarted $entry $cluster.id;Phase $entry 'Started'}
            if ($script:ProvisionOnly) {
                return [pscustomobject]@{Hostname=$entry.Hostname;Succeeded=$true;Entry=$entry}
            }
            if ($entry.Phase -in @('Started','RenamePending')) {
                $session=Connect-Guest $entry $local
                $id=Invoke-Command -Session $session -ScriptBlock $script:Identity
                if (-not $entry.PreviousBoot -or $entry.Phase -eq 'Started') {$entry.PreviousBoot=$id.Boot;Phase $entry 'RenamePending'}
                if ($id.Name -ine $entry.Hostname -or $id.Boot -eq $entry.PreviousBoot) {
                    Invoke-Command -Session $session -ScriptBlock $script:GuestScheduleRename -ArgumentList $entry.Hostname,$Config.DomainControllerIP
                }
                Remove-PSSession $session;$session=$null
                # The guest task owns reboot. Do not schedule another reboot from the controller here.
                $session=Connect-Guest $entry $local $entry.PreviousBoot
                $renamed=Invoke-Command -Session $session -ScriptBlock $script:Identity
                if ($renamed.Name -ine $entry.Hostname) {throw 'Hostname after reboot does not match the requested name.'}
                Remove-PSSession $session;$session=$null
                Phase $entry 'Renamed'
            }
            if ($entry.Phase -in @('Renamed','JoinPending')) {
                $session=Connect-Guest $entry $local
                $id=Invoke-Command -Session $session -ScriptBlock $script:Identity
                if ($id.Name -ine $entry.Hostname) {throw 'Hostname verification failed.'}
                if ($entry.Phase -eq 'Renamed') {$entry.PreviousBoot=$id.Boot;Phase $entry 'JoinPending'}
                Invoke-Command -Session $session -ScriptBlock {
                    param($Domain,$OU,[pscredential]$Cred)
                    $cs=Get-CimInstance Win32_ComputerSystem
                    if ($cs.PartOfDomain) {if ($cs.Domain -ine $Domain) {throw 'Already joined to another domain.'};return}
                    $receipt='C:\ProgramData\SimpleVDI-join.json'
                    if (Test-Path $receipt) {$prior=Get-Content $receipt -Raw | ConvertFrom-Json;if ($prior.Code -eq 0 -and $prior.Domain -ieq $Domain) {return}}
                    $joinArgs=@{Name=$Domain;UserName=$Cred.UserName;Password=$Cred.GetNetworkCredential().Password;FJoinOptions=[uint32]131075}
                    if ($OU) {$joinArgs.AccountOU=$OU}
                    try {$result=Invoke-CimMethod -InputObject $cs -MethodName JoinDomainOrWorkgroup -Arguments $joinArgs} finally {$joinArgs.Password=$null}
                    @{Code=$result.ReturnValue;Domain=$Domain} | ConvertTo-Json | Set-Content $receipt
                    if ($result.ReturnValue -ne 0) {throw "Domain join failed: Win32Code=$($result.ReturnValue)"}
                } -ArgumentList $Config.DomainName,$Config.OUPath,$ad
                Remove-PSSession $session;$session=$null
                Restart-GuestAndWait $entry $local;Phase $entry 'Joined'
            }
            if ($entry.Phase -in @('Joined','Installing')) {
                $session=Connect-Guest $entry $ad
                Invoke-Command -Session $session -ScriptBlock {
                    param($Name,$Domain)
                    $cs=Get-CimInstance Win32_ComputerSystem
                    if ($env:COMPUTERNAME -ine $Name -or -not $cs.PartOfDomain -or $cs.Domain -ine $Domain -or -not (Test-ComputerSecureChannel)) {throw 'Guest hostname/domain/secure-channel validation failed.'}
                    $null=New-Item 'C:\ProgramData\VDIDeploy' -ItemType Directory -Force
                    & icacls.exe 'C:\ProgramData\VDIDeploy' /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
                    if ($LASTEXITCODE -ne 0) {throw 'Cannot secure installer directory.'}
                } -ArgumentList $entry.Hostname,$Config.DomainName
                Write-Host "$($entry.Hostname): Disabling Domain, Private, and Public Windows Firewall profiles."
                $firewall=Invoke-Command -Session $session -ScriptBlock $script:GuestDisableFirewall
                Write-Host "$($entry.Hostname): All Windows Firewall profiles are disabled and verified."
                Phase $entry 'Installing' 
                $remote=$Config.AgentSourcePath
                $entry.TransferSeconds=0
                Write-Host "$($entry.Hostname): using the installer preloaded in the guest at $remote."
                Write-Host "$($entry.Hostname): starting local Agent installation without a separate installation gate."
                $installWatch=[Diagnostics.Stopwatch]::StartNew()
                $result=Invoke-Command -Session $session -ScriptBlock $script:GuestInstall -ArgumentList $remote,'',$Config.ConnectionServer,$Config.AgentFeatures,$horizon,$Config.InstallTimeoutSeconds,$Config.ValidateInstallerSignature
                $entry.InstallSeconds=[Math]::Round($installWatch.Elapsed.TotalSeconds,1);Save-State
                Write-Host "$($entry.Hostname): Agent installer completed in $($entry.InstallSeconds) seconds."
                $entry.AgentExitCode=$result.ExitCode;$entry.PreviousBoot=$result.Boot;Phase $entry 'AgentRebootPending'
                Remove-PSSession $session;$session=$null
            }
            if ($entry.Phase -eq 'AgentRebootPending') {Restart-GuestAndWait $entry $ad;Phase $entry 'Installed'}
            if ($entry.Phase -in @('Installed','Verified')) {
                $session=Connect-Guest $entry $ad
                $firewall=Invoke-Command -Session $session -ScriptBlock $script:GuestDisableFirewall
                $verification=Invoke-Command -Session $session -ScriptBlock $script:GuestVerify -ArgumentList $entry.Hostname,$Config.DomainName,$false
                Invoke-Command -Session $session -ScriptBlock $script:GuestCleanupAgent -ArgumentList $Config.AgentSourcePath
                $entry.AgentService=$verification.Service
                Invoke-Command -Session $session -ScriptBlock {Remove-Item 'C:\ProgramData\SimpleVDI\Unattend.xml' -Force -ErrorAction SilentlyContinue}
                Phase $entry 'Verified'
                Write-Host "$($entry.Hostname): Agent service wsnm is running after reboot. Broker registration must be confirmed in Horizon Console."
            }
        } catch {
            $success=$false;$message=($_.Exception.Message -split '[\r\n]')[0]
            foreach ($secret in @(Get-AocRequestSecrets $Config;foreach ($redactionCredential in @($local,$ad,$horizon)) {if ($redactionCredential) {$redactionCredential.GetNetworkCredential().Password}})) {if ($secret) {$message=$message.Replace($secret,'[REDACTED]')}}
            $entry.Error=$message;Save-State;Write-Warning "$($entry.Hostname): $message"
        } finally {if ($session) {Remove-PSSession $session -ErrorAction SilentlyContinue}}
    [pscustomobject]@{Hostname=$entry.Hostname;Succeeded=$success}
}
$interactiveCredentials=$null;$script:Config=$null
$reconcilePending=$false
$script:AocToken='';$lock=$null;$originalTrusted=$null;$trustedSaved=$false
try {
    if (-not $IsWindows) { throw 'Use elevated PowerShell 7.2+ on the Windows controller.' }
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {throw 'Run elevated.'}
    $script:Config=Get-Content $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
    $interactiveCredentials=Set-InteractiveCredentials $Config @('Aoc','Local','Domain','Horizon')
    $local=$interactiveCredentials.Local;$ad=$interactiveCredentials.Domain;$horizon=$interactiveCredentials.Horizon
    if ($Config.ContainsKey('CloneConcurrency')) {Write-Host 'CloneConcurrency is retired and ignored. Concurrency controls both pipeline stages.'}
    $runtime=Resolve-DeploymentRuntimeSettings $Config $PSBoundParameters
    foreach ($key in @('TimeoutSeconds','InstallTimeoutSeconds','PollSeconds')) {$Config[$key]=$runtime[$key]}
    $Concurrency=$runtime.Concurrency;$CloneConcurrency=$runtime.CloneConcurrency
    if ($Concurrency -gt 20) {Write-Warning 'Concurrency above 20 exceeds the engineering recommendation. Use 20 or less unless validated for your environment.'}
    $FastPollSeconds=$runtime.FastPollSeconds;$RebootTimeoutSeconds=$runtime.RebootTimeoutSeconds
    $script:RuntimePollSeconds=$FastPollSeconds;$script:RuntimeRebootTimeout=$RebootTimeoutSeconds
    foreach ($key in @('AocUrl','AocUsername','TemplateName','ClusterName','LocalUsername','DomainName','DomainControllerIP','DomainUsername','ConnectionServer','HorizonUsername','AgentSourcePath')) {if (-not $Config[$key]) {throw "Required configuration: $key"}}
    if ($Config.AocUrl -notmatch '^https://') {throw 'AocUrl must use HTTPS.'}
    foreach ($key in @('CpuCount','MemoryGB','TimeoutSeconds','InstallTimeoutSeconds','PollSeconds')) {if ([int]$Config[$key] -lt 1 -or [double]$Config[$key] -ne [int]$Config[$key]) {throw "Invalid positive integer: $key"}}
    $fullCopy=Get-DeploymentFullCopy $Config
    Write-Host "AOC clone is_full_copy: $fullCopy"
    $names=@(Get-DeploymentNames $Config)
    Write-Host "VM name = Windows hostname: $($names -join ', ')"
    if ($Config.DomainName -notmatch '^[A-Za-z0-9.-]+$' -or $Config.ConnectionServer -notmatch '^[A-Za-z0-9.-]+$' -or $Config.AgentFeatures -notmatch '^[A-Za-z0-9]+(,[A-Za-z0-9]+)*$') {throw 'Invalid domain / CS / feature list.'}
    if ($Config.HorizonUsername -match '["\r\n]' -or $horizon.GetNetworkCredential().Password -match '["\r\n]' -or $horizon.GetNetworkCredential().Password.EndsWith('\')) {throw 'Horizon credentials contain unsupported installer quoting characters.'}
    Assert-HorizonUsername $Config.HorizonUsername
    if ($Config.AgentSourcePath -notmatch '^C:\\[^\\/:*?"<>|]+\.exe$') {throw 'AgentSourcePath must be an EXE directly under C:\ inside the golden template, for example C:\HorizonAgent.exe.'}
    $installer=[pscustomobject]@{FullName=$Config.AgentSourcePath}
    $script:AocBase=($Config.AocUrl.TrimEnd('/') -replace '/v2/api$','')+'/v2/api'
    $login=Invoke-Aoc 'login' @{username=$Config.AocUsername;password=$interactiveCredentials.Aoc.GetNetworkCredential().Password;source=$Config.AocUserSource}
    $script:AocToken=$login.data.token
    $template=Get-AocOne 'get-content-library-vm-templates' @{name=$Config.TemplateName}
    $cluster=Get-AocOne 'get-clusters' @{name=$Config.ClusterName}
    $script:StateFile=Resolve-DeploymentFilePath $StatePath
    if (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($StateFile,'.cleanup.json'))) {throw 'Cleanup has started for this batch. Do not resume deployment with this StatePath; review the cleanup receipt and use a new batch for new VMs.'}
    if (-not [IO.Path]::IsPathRooted($StatePath)) {
        $legacyPath=[IO.Path]::GetFullPath($StatePath)
        if ($legacyPath -ine $StateFile -and (Test-Path -LiteralPath $legacyPath)) {
            throw "A state file exists at the legacy process-relative path: $legacyPath. Intended PowerShell path: $StateFile. Inspect both files and pass the correct absolute StatePath; no deployment was started."
        }
    }
    Write-Host "Resolved batch state: $StateFile"
    $null=New-Item (Split-Path $StateFile) -ItemType Directory -Force
    $lock=[IO.File]::Open("$StateFile.lock",'OpenOrCreate','ReadWrite','None')
    $hash=Get-PublicConfigHash $Config
    if (Test-Path $StateFile) {
        $script:State=Get-Content $StateFile -Raw | ConvertFrom-Json -AsHashtable
        if ($State.ConfigHash -ne $hash) {
            if (Test-HorizonUsernameMigration $Config $State.ConfigHash) {
                $State.ConfigHash=$hash
                Write-Host 'Accepted HorizonUsername UPN-to-domain\username correction; resuming existing VMs.'
            } elseif (Test-CloneModeMigration $Config $State.ConfigHash) {
                $State.ConfigHash=$hash
                Write-Host 'Accepted legacy full-copy to non-full-copy configuration change. Only VMs in New phase use the new mode; existing/pending VMs are preserved.'
            } else {
                $compatibility=Get-ConfigCompatibilityReason $Config $State.ConfigHash
                if ($compatibility) {
                    $State.ConfigHash=$hash
                    Write-Host "Accepted configuration compatibility migration: $compatibility Only New VMs use a changed clone mode."
                } elseif ($ReconcileConfig) {
                    Assert-BatchConfigReconciliation $State $names
                    $reconcilePending=$true
                } else {throw 'Config changed. Run Get-BatchConfigDiagnostics.ps1 with the original StatePath. Do not delete state or recreate existing VMs.'}
            }
        }
    }
    else {$script:State=@{ConfigHash=$hash;Entries=@($names | ForEach-Object {@{Hostname=$_;Tag=('SimpleVDI:'+ [guid]::NewGuid());VmId='';TaskId='';Phase='New';IP='';PreviousBoot='';Error=''}})}}
    if ($ReconcileConfig) {Assert-BatchConfigReconciliation $State $names}
    foreach ($entry in $State.Entries) {
        $found=@(Invoke-Aoc 'get-vms' @{where=@{name=$entry.Hostname};first=2})
        if ($found.Count -and -not ($found.Count -eq 1 -and (Get-AocOptionalProperty $found[0] 'description') -eq $entry.Tag)) {throw "VM name conflict: $($entry.Hostname)"}
        if ($entry.VmId) {
            $savedVm=Get-AocVm $entry.VmId
            if ($savedVm.name -ine $entry.Hostname -or (Get-AocOptionalProperty $savedVm 'description') -ne $entry.Tag -or $savedVm.cluster.id -ne $cluster.id) {throw 'Saved VM ownership no longer matches.'}
        }
        if (-not $entry.VmId -and $found.Count -eq 1) {$entry.VmId=$found[0].id}
    }
    if ($reconcilePending) {
        Write-Host 'Recovery review: all saved VM names, ownership tags and cluster IDs matched AOC.'
        Write-Host "State: $StateFile; existing VM count: $($State.Entries.Count)"
        Write-Host "Target domain: $($Config.DomainName); DNS/DC: $($Config.DomainControllerIP); join account: $($Config.DomainUsername)"
        Write-Host "Connection Server: $($Config.ConnectionServer); registration account: $($Config.HorizonUsername)"
        Write-Host "Installer source: $($installer.FullName)"
        Write-Host 'These current settings will be adopted only when ValidateOnly is omitted. No VM creation or clone resubmission is allowed during reconciliation.'
    }
    if ($ValidateOnly) {Write-Host 'AOC resources, config and VM names passed. No guests created. Guest installer presence/signature and template WinRM/OOBE require a clone test.';return}
    if ($reconcilePending) {
        $backup="$StateFile.before-reconcile-$(Get-Date -Format yyyyMMdd-HHmmss)-$([guid]::NewGuid().ToString('N')).json"
        Copy-Item -LiteralPath $StateFile -Destination $backup -ErrorAction Stop
        $State.ConfigHash=$hash
        $State.ReconciledUtc=[datetime]::UtcNow.ToString('o')
        Write-Host "Original state backed up to: $backup"
    }
    $publicSnapshot=@{}
    foreach ($key in $Config.Keys) {if ($key -notmatch 'Password$') {$publicSnapshot[$key]=$Config[$key]}}
    $State.PublicConfig=$publicSnapshot
    Save-State
    Start-Service WinRM
    $originalTrusted=[string](Get-Item WSMan:\localhost\Client\TrustedHosts).Value;$trustedSaved=$true
    Write-Host "Worker concurrency: $Concurrency; clone slots: $CloneConcurrency; Agent installation: no separate limit; polling: $FastPollSeconds seconds."
    if ($Concurrency -eq 1) {
        $results=@(foreach ($entry in $State.Entries) {Invoke-EntryDeployment $entry})
    } else {
        $definitions=@('New-DeploymentCredential','Save-State','Phase','Connect-Guest','Restart-GuestAndWait','Invoke-EntryDeployment') | ForEach-Object {
            "function $_ {`n$((Get-Command $_ -CommandType Function).Definition)`n}"
        }
        $runner='param($context,$entry,[bool]$provisionOnly)'  + "`n" + @'
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$script:ParallelContext=$context
$script:ProvisionOnly=$provisionOnly
$script:WorkerEntry=$entry
$script:Config=$context.Config
$script:StateFile=$context.StateFile
$script:AocBase=$context.AocBase
$script:AocToken=$context.AocToken
$script:CloneGate=$context.CloneGate
$script:RuntimePollSeconds=$context.PollSeconds
$script:RuntimeRebootTimeout=$context.RebootTimeoutSeconds
foreach ($library in @('Aoc','Agent','Rename','GuestCredentials','Firewall','Parallel','Performance','Config')) { . (Join-Path $context.Root "lib/$library.ps1") }
$script:Identity=[scriptblock]::Create($context.Identity)
$local=$context.LocalCredential;$ad=$context.DomainCredential;$horizon=$context.HorizonCredential
$template=$context.Template;$cluster=$context.Cluster
$installer=[pscustomobject]@{FullName=$context.InstallerPath}
'@ + "`n" + ($definitions -join "`n") + "`nInvoke-EntryDeployment `$entry"
        $context=@{Gate=[object]::new();State=$State;StateFile=$StateFile;Root=$PSScriptRoot;Config=$Config;AocBase=$script:AocBase;AocToken=$script:AocToken;Identity=$script:Identity.ToString();LocalCredential=$local;DomainCredential=$ad;HorizonCredential=$horizon;Template=$template;Cluster=$cluster;InstallerPath=$installer.FullName;CloneGate=[Threading.SemaphoreSlim]::new($CloneConcurrency,$CloneConcurrency);PollSeconds=$FastPollSeconds;RebootTimeoutSeconds=$RebootTimeoutSeconds;PipelineProvisioning=$true;CloneConcurrency=$CloneConcurrency}
        try {$results=@(Invoke-ParallelDeployment $State.Entries $Concurrency $context $runner)}
        finally {$context.CloneGate.Dispose()}
    }
    $failed=@($results | Where-Object {-not $_.Succeeded}).Count
    $State.Entries | ForEach-Object {[pscustomobject]@{Hostname=$_.Hostname;VmId=$_.VmId;IP=$_.IP;Phase=$_.Phase;AgentService=(Get-AocOptionalProperty $_ 'AgentService');InstallerExitCode=(Get-AocOptionalProperty $_ 'AgentExitCode');CloneFullCopy=(Get-AocOptionalProperty $_ 'CloneFullCopy');CloneQueueSeconds=(Get-AocOptionalProperty $_ 'CloneQueueSeconds');Error=$_.Error}} | Export-Csv ([IO.Path]::ChangeExtension($StateFile,'.csv')) -NoTypeInformation -Encoding utf8BOM
    $timings=@(foreach ($entry in $State.Entries) {
        $phases=Get-AocOptionalProperty $entry 'PhaseSeconds'
        if ($phases) {foreach ($phaseName in $phases.Keys) {
            [pscustomobject]@{Hostname=$entry.Hostname;Phase=$phaseName;ElapsedSeconds=$phases[$phaseName];TransferSeconds=(Get-AocOptionalProperty $entry 'TransferSeconds');InstallSeconds=(Get-AocOptionalProperty $entry 'InstallSeconds')}
        }}
    })
    $timingPath=[IO.Path]::ChangeExtension($StateFile,'timings.csv')
    $timings | Export-Csv $timingPath -NoTypeInformation -Encoding utf8BOM
    Write-Host "Phase timing report: $timingPath"
    if ($failed) {throw "$failed VM(s) failed. Fix the cause and rerun with the same config/state."}
} finally {
    Write-Progress -Activity 'Simple Horizon deployment' -Completed
    if ($trustedSaved) {Set-Item WSMan:\localhost\Client\TrustedHosts -Value $originalTrusted -Force}
    if ($lock) {$lock.Dispose()}
    $script:AocToken=''
    Clear-InteractiveCredentials $script:Config $interactiveCredentials
    $local=$null;$ad=$null;$horizon=$null;$context=$null
}
