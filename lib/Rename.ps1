# Submit before disruptive changes. Task runs as SYSTEM after the remote call has returned.
$script:GuestScheduleRename={
    param([string]$Name,[string]$Dns)
    $ErrorActionPreference='Stop'
    $taskName='SimpleVDI-Rename'
    $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        $info=Get-ScheduledTaskInfo -TaskName $taskName
        if ($task.State -eq 'Running' -or $info.NextRunTime -gt (Get-Date)) {return}
    }
    $dir='C:\ProgramData\SimpleVDI'
    $null=New-Item $dir -ItemType Directory -Force
    & icacls.exe $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) {throw 'Cannot secure rename task directory.'}
    $settings=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{Name=$Name;Dns=$Dns} | ConvertTo-Json -Compress)))
    $code=@'
$ErrorActionPreference='Stop'
$settings=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__SETTINGS__')) | ConvertFrom-Json
$receipt='C:\ProgramData\SimpleVDI\rename-result.json'
try {
    $nics=@(Get-NetAdapter -Physical | Where-Object Status -eq Up)
    if ($nics.Count -ne 1) {throw 'Require one active NIC.'}
    $index=$nics[0].ifIndex
    $net=Get-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4
    if ($net.Dhcp -ne 'Enabled') {Set-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -Dhcp Enabled}
    Set-DnsClientServerAddress -InterfaceIndex $index -ServerAddresses $settings.Dns
    $pending=(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName').ComputerName
    if ($env:COMPUTERNAME -ine $settings.Name -and $pending -ine $settings.Name) {Rename-Computer -NewName $settings.Name -Force}
    @{Status='Configured';Name=$settings.Name;Dns=$settings.Dns} | ConvertTo-Json | Set-Content $receipt
    & shutdown.exe /r /t 10 /f | Out-Null
    if ($LASTEXITCODE -ne 0) {throw 'Reboot scheduling failed.'}
} catch {
    @{Status='Failed';Name=$settings.Name;Error=$_.Exception.Message} | ConvertTo-Json | Set-Content $receipt
    exit 1
}
'@
    $code=$code.Replace('__SETTINGS__',$settings)
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    $action=New-ScheduledTaskAction -Execute "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
    $trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(30)
    Remove-Item "$dir\rename-result.json" -Force -ErrorAction SilentlyContinue
    $null=Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -User SYSTEM -RunLevel Highest -Force
}
