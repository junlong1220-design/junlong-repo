. "$PSScriptRoot/State.ps1"
function Assert-CleanupVm {
    param($Entry,$Vm,[string]$ClusterId)
    $inRecycle=Get-AocOptionalProperty $Vm 'in_recycle_bin'
    $actualName=[string](Get-AocOptionalProperty $Vm 'name')
    # AOC replaces the display name when moving a VM to the recycle bin.
    # Only permit that name form when the API explicitly confirms recycle state.
    $recycledName=($inRecycle -is [bool] -and $inRecycle -and
        $actualName -match '^in-recycle-bin-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
    $actualClusterId=Get-AocOptionalProperty (Get-AocOptionalProperty $Vm 'cluster') 'id'
    if (-not $Entry.VmId -or -not $Entry.Tag -or $Entry.Tag -notlike 'SimpleVDI:*' -or
        (Get-AocOptionalProperty $Vm 'id') -ne $Entry.VmId -or
        ($actualName -ine $Entry.Hostname -and -not $recycledName) -or
        (Get-AocOptionalProperty $Vm 'description') -cne $Entry.Tag -or $actualClusterId -ne $ClusterId) {
        throw "Cleanup ownership verification failed: $($Entry.Hostname). Expected ID/name/tag/cluster did not match (recycled names require in_recycle_bin=true)."
    }
}
# Runs on the DNS server. Enumerate exact owners and exact PTR targets, never wildcard prefixes or IP-only matches.
$script:CleanupDnsRecords={
    param([string]$Zone,[string[]]$Names,[bool]$Delete)
    $ErrorActionPreference='Stop'
    Import-Module DnsServer -ErrorAction Stop
    $zones=@(Get-DnsServerZone)
    if (-not ($zones | Where-Object {$_.ZoneName -ieq $Zone -and -not $_.IsReverseLookupZone})) {throw "Forward DNS zone not found: $Zone"}
    foreach ($name in $Names) {
        $fqdn="$name.$Zone".TrimEnd('.').ToLowerInvariant()
        $records=@(Get-DnsServerResourceRecord -ZoneName $Zone | Where-Object {$_.HostName -ieq $name -and $_.RecordType -in @('A','AAAA')})
        foreach ($record in $records) {
            if ($Delete) {Remove-DnsServerResourceRecord -ZoneName $Zone -InputObject $record -Force -ErrorAction Stop}
            [pscustomobject]@{VM=$name;Zone=$Zone;Owner=$record.HostName;Type=$record.RecordType;Deleted=$Delete}
        }
        foreach ($reverse in @($zones | Where-Object IsReverseLookupZone)) {
            foreach ($record in @(Get-DnsServerResourceRecord -ZoneName $reverse.ZoneName -RRType PTR)) {
                if ([string]$record.RecordData.PtrDomainName -and $record.RecordData.PtrDomainName.TrimEnd('.').ToLowerInvariant() -eq $fqdn) {
                    if ($Delete) {Remove-DnsServerResourceRecord -ZoneName $reverse.ZoneName -InputObject $record -Force -ErrorAction Stop}
                    [pscustomobject]@{VM=$name;Zone=$reverse.ZoneName;Owner=$record.HostName;Type='PTR';Deleted=$Delete}
                }
            }
        }
    }
}

function Write-CleanupReceipt {
    param([string]$Path,$Receipt)
    Write-DeploymentStateFile -Path $Path -Value $Receipt
}

function Save-ParallelCleanupRow($Context,$Row) {
    $snapshot=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Row -Depth 20)
    [Threading.Monitor]::Enter($Context.Gate)
    try {
        $matches=@(0..($Context.Receipt.Entries.Count-1) | Where-Object {$Context.Receipt.Entries[$_].VmId -eq $snapshot.VmId})
        if ($matches.Count -ne 1) {throw 'Cleanup row does not belong to this receipt.'}
        $index=$matches[0];$existing=$Context.Receipt.Entries[$index]
        if ($existing.Hostname -ine $snapshot.Hostname -or $existing.Tag -cne $snapshot.Tag) {throw 'Cleanup row ownership changed.'}
        $Context.Receipt.Entries[$index]=$snapshot
        Write-CleanupReceipt -Path $Context.ReceiptPath -Receipt $Context.Receipt
    } finally {[Threading.Monitor]::Exit($Context.Gate)}
}
