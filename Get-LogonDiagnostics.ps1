#requires -Version 5.1
[CmdletBinding()]
param([int]$Minutes=30)
$ErrorActionPreference='Continue'
$computer=Get-CimInstance Win32_ComputerSystem
Write-Output '=== Computer and domain ==='
$computer | Select-Object Name,Domain,PartOfDomain | Format-List
Write-Output '=== Network and DNS ==='
Get-NetIPConfiguration | Format-List InterfaceAlias,IPv4Address,IPv4DefaultGateway,DNSServer
Get-DnsClientServerAddress -AddressFamily IPv4 | Format-Table -AutoSize
if ($computer.PartOfDomain) {
    Write-Output '=== Domain controller discovery ==='
    & nltest.exe "/dsgetdc:$($computer.Domain)"
    Resolve-DnsName "_ldap._tcp.dc._msdcs.$($computer.Domain)" -Type SRV
    Write-Output '=== Machine secure channel (no repair) ==='
    try { Test-ComputerSecureChannel -Verbose -ErrorAction Stop } catch {Write-Warning $_.Exception.Message}
    Write-Output '=== Time synchronization ==='
    & w32tm.exe /query /status
}
Write-Output '=== Recent sign-in and Group Policy events ==='
$start=(Get-Date).AddMinutes(-$Minutes)
foreach ($log in @('Microsoft-Windows-GroupPolicy/Operational','Microsoft-Windows-User Profile Service/Operational','Application','System')) {
    Write-Output "--- $log ---"
    try {
        $events=Get-WinEvent -FilterHashtable @{LogName=$log;StartTime=$start} -MaxEvents 150 -ErrorAction Stop
        if ($log -in @('Application','System')) {
            $events=$events | Where-Object {$_.Level -le 3 -or $_.ProviderName -match 'Profile|GroupPolicy|NETLOGON|DNS|Time-Service'}
        }
        $events | Select-Object TimeCreated,Id,LevelDisplayName,ProviderName,Message | Format-List
    } catch {Write-Warning "$log : $($_.Exception.Message)"}
}
