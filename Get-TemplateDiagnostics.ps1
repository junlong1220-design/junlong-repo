#requires -Version 5.1
# Run elevated INSIDE the failed clone or source template. Read-only diagnostics.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber
Get-CimInstance Win32_ComputerSystem | Select-Object Name,Domain,PartOfDomain
Get-LocalUser | Select-Object Name,Enabled,PasswordExpires,LastLogon
Get-LocalGroupMember -SID 'S-1-5-32-544'
Get-Service WinRM
Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceAlias,IPAddress
Get-Item WSMan:\localhost\Service\Auth\Negotiate -ErrorAction Continue
foreach ($path in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System','HKLM:\SYSTEM\CurrentControlSet\Control\Lsa','HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0','HKLM:\SOFTWARE\Policies\Microsoft\Windows\WinRM\Service')) {
    Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue | Select-Object PSPath,LocalAccountTokenFilterPolicy,ForceGuest,RestrictReceivingNTLMTraffic,AllowNegotiate,AllowAutoConfig
}
$temporary=Join-Path $env:TEMP (('SimpleVDI-policy-'+[guid]::NewGuid().ToString('N'))+'.inf')
try {
    & secedit.exe /export /cfg $temporary /areas USER_RIGHTS /quiet | Out-Null
    if ($LASTEXITCODE -eq 0) {Get-Content -LiteralPath $temporary | Where-Object {$_ -match '^Se(DenyNetworkLogonRight|NetworkLogonRight)\s*='}}
} finally {Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}
Write-Host 'Recent failed network logons (Security event 4625, if auditing is enabled):'
$events=@(Get-WinEvent -FilterHashtable @{LogName='Security';Id=4625;StartTime=(Get-Date).AddHours(-2)} -MaxEvents 15 -ErrorAction SilentlyContinue)
foreach ($event in $events) {
    [xml]$xml=$event.ToXml();$data=@{}
    foreach ($item in $xml.Event.EventData.Data) {$data[[string]$item.Name]=[string]$item.'#text'}
    [pscustomobject]@{Time=$event.TimeCreated;User=$data.TargetUserName;Domain=$data.TargetDomainName;LogonType=$data.LogonType;Status=$data.Status;SubStatus=$data.SubStatus;ClientIP=$data.IpAddress} | Format-List
}
Write-Host 'Diagnostics complete. No policies were changed. Missing 4625 events do not prove authentication succeeded.'
