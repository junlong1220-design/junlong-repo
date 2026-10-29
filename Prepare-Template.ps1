#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ControllerIP,[string]$Locale='en-US',[string]$InputLocale='0409:00000409')
$ErrorActionPreference='Stop'
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {throw 'Run elevated.'}
if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) {throw 'Template must be in a workgroup.'}
$ip=$null;if (-not [Net.IPAddress]::TryParse($ControllerIP,[ref]$ip)) {throw 'ControllerIP must be an IP address.'}
$credential=Get-Credential -UserName Admin -Message 'Local template Admin: use the same password at the deployment local administrator prompt'
if ($credential.UserName -cne 'Admin') {throw 'Use local user Admin.'}
$null=Get-LocalUser Admin
Enable-LocalUser Admin
Set-LocalUser Admin -Password $credential.Password
$members=@(Get-LocalGroupMember -SID 'S-1-5-32-544')
if ((Get-LocalUser Admin).SID.Value -notin @($members | ForEach-Object {$_.SID.Value})) {Add-LocalGroupMember -SID 'S-1-5-32-544' -Member Admin}
$nics=@(Get-NetAdapter -Physical | Where-Object Status -eq Up)
if ($nics.Count -ne 1) {throw 'Require one active NIC.'}
Write-Host 'Applying first-logon privacy and data-export notice settings.'
# Microsoft KB5028723 documents PDEShown=2 per local user for Enterprise/Education.
# Default-profile inheritance is a deployment adaptation; validate with a clone.
$policy='HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE'
$null=New-Item -Path $policy -Force
$null=New-ItemProperty -Path $policy -Name DisablePrivacyExperience -PropertyType DWord -Value 1 -Force
$pde='Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\PersonalDataExport'
$current="HKCU:\$pde"
$null=New-Item -Path $current -Force
$null=New-ItemProperty -Path $current -Name PDEShown -PropertyType DWord -Value 2 -Force
$defaultHive=Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
if (-not (Test-Path -LiteralPath $defaultHive)) {throw 'Default user registry hive was not found.'}
$mount='SimpleVDI_Default_'+[guid]::NewGuid().ToString('N')
$loaded=$false
try {
    & reg.exe load "HKU\$mount" $defaultHive | Out-Null
    if ($LASTEXITCODE -ne 0) {throw 'Failed to load the Default user registry hive.'}
    $loaded=$true
    & reg.exe add "HKU\$mount\$pde" /v PDEShown /t REG_DWORD /d 2 /f | Out-Null
    if ($LASTEXITCODE -ne 0) {throw 'Failed to set PDEShown in the Default user registry hive.'}
} finally {
    if ($loaded) {
        & reg.exe unload "HKU\$mount" | Out-Null
        if ($LASTEXITCODE -ne 0) {throw 'Failed to unload the Default user registry hive. Resolve this before Sysprep.'}
    }
}
Write-Host "Configured current user: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)."
Write-Host 'Configured Default profile for future users and disabled the generic first-logon privacy experience.'
Write-Host 'Existing profiles other than the current user were not modified. Run under each required local account if necessary.'
if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne (Get-LocalUser Admin).SID.Value) {
    Write-Warning 'The current account is not local Admin. Existing Admin profile settings are not updated by HKCU; run this script while signed in as local Admin for complete first-logon optimization.'
}

Set-NetIPInterface -InterfaceIndex $nics[0].ifIndex -AddressFamily IPv4 -Dhcp Enabled
Set-DnsClientServerAddress -InterfaceIndex $nics[0].ifIndex -ResetServerAddresses
if (Get-Service cloudbase-init -ErrorAction SilentlyContinue) {Stop-Service cloudbase-init -Force;Set-Service cloudbase-init -StartupType Disabled}
$bootstrap=@'
$ErrorActionPreference='Stop'
# Keep the existing network category. Enable remoting explicitly for Public profiles.
Enable-PSRemoting -Force -SkipNetworkProfileCheck
Set-Service WinRM -StartupType Automatic
Start-Service WinRM
# Do not issue WinRM configuration-provider Get/Put calls here: on some
# Public-profile images that provider rejects even unrelated config writes.
# Inspect persisted settings without altering them. Missing entries use Windows defaults.
function Read-WinRMSetting($Path,$Name,$Default) {
    $value=Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if ($value -and $null -ne $value.$Name) {return [int]$value.$Name}
    return $Default
}
$serviceRegistry='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WSMAN\Service'
$policyRegistry='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WinRM\Service'
$allowUnencrypted=Read-WinRMSetting $policyRegistry 'AllowUnencryptedTraffic' (Read-WinRMSetting $serviceRegistry 'AllowUnencrypted' 0)
$allowBasic=Read-WinRMSetting $policyRegistry 'AllowBasic' (Read-WinRMSetting "$serviceRegistry\Auth" 'Basic' 0)
$allowNegotiate=Read-WinRMSetting $policyRegistry 'AllowNegotiate' (Read-WinRMSetting "$serviceRegistry\Auth" 'Negotiate' 1)
if ($allowUnencrypted -ne 0 -or $allowBasic -ne 0 -or $allowNegotiate -ne 1) {
    throw 'WinRM settings/policy conflict: require AllowUnencrypted=false, Basic=false and Negotiate=true. Review local/group policy; the script does not bypass these security settings.'
}
Write-Host 'WinRM persisted settings/policy checks passed. Network category was not changed.'
$null=New-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name LocalAccountTokenFilterPolicy -Value 1 -PropertyType DWord -Force
Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP*' -ErrorAction SilentlyContinue | Disable-NetFirewallRule
Get-NetFirewallRule -Name SimpleVDI-WinRM -ErrorAction SilentlyContinue | Remove-NetFirewallRule
$null=New-NetFirewallRule -Name SimpleVDI-WinRM -DisplayName 'Simple VDI WinRM controller' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5985 -RemoteAddress '__CONTROLLER__' -Profile Any
'@
# Run preparation after OSOT Optimize/Finalize so later tool runs do not overwrite it.
$bootstrap=$bootstrap.Replace('__CONTROLLER__',$ControllerIP)
& ([scriptblock]::Create($bootstrap))
# Prove that the configured local account can use the same WinRM endpoint as deployment.
$probe=$null
try {
    $probeCredential=[pscredential]::new("$env:COMPUTERNAME\Admin",$credential.Password)
    $probe=New-PSSession -ComputerName localhost -Authentication Negotiate -Credential $probeCredential -ErrorAction Stop
    $identity=Invoke-Command -Session $probe -ScriptBlock {whoami.exe}
    Write-Host "Local WinRM credential check passed: $identity"
} catch {throw "Template WinRM credential check failed after optimization: $($_.Exception.Message). Run Get-TemplateDiagnostics.ps1 inside this VM. Do not seal this template until the check passes."}
finally {if ($probe) {Remove-PSSession $probe};$probeCredential=$null}
Write-Host "For the first clone connection, the local credential prompt can use $env:COMPUTERNAME\Admin."
# Native Windows startup task restores remoting after Sysprep; no Cloudbase or credentials in the task.
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
$action=New-ScheduledTaskAction -Execute "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
$trigger=New-ScheduledTaskTrigger -AtStartup
$null=Register-ScheduledTask -TaskName SimpleVDI-EnableRemoting -Action $action -Trigger $trigger -User SYSTEM -RunLevel Highest -Force
$dir='C:\ProgramData\SimpleVDI'
$null=New-Item $dir -ItemType Directory -Force
& icacls.exe $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) {throw 'Cannot secure preparation directory.'}
# Complete standard Windows OOBE using native answer-file settings; no interactive domain autologon.
$password=[Security.SecurityElement]::Escape($credential.GetNetworkCredential().Password)
$localeXml=[Security.SecurityElement]::Escape($Locale)
$inputXml=[Security.SecurityElement]::Escape($InputLocale)
$xml=@"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
 <settings pass="oobeSystem">
  <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
   <InputLocale>$inputXml</InputLocale><SystemLocale>$localeXml</SystemLocale><UserLocale>$localeXml</UserLocale>
  </component>
  <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
   <OOBE><HideEULAPage>true</HideEULAPage><HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE><ProtectYourPC>3</ProtectYourPC></OOBE>
   <UserAccounts><LocalAccounts><LocalAccount wcm:action="add"><Name>Admin</Name><Group>Administrators</Group><Password><Value>$password</Value><PlainText>true</PlainText></Password></LocalAccount></LocalAccounts></UserAccounts>
  </component>
 </settings>
</unattend>
"@
$path=Join-Path $dir Unattend.xml
[IO.File]::WriteAllText($path,$xml,[Text.UTF8Encoding]::new($false))
$password=$null;$xml=$null
Write-Host 'Template preparation and first-logon optimization completed.'
Write-Host 'Validate one generalized clone before publishing the production template.'
Write-Host 'Prepared. Answer file contains the local bootstrap password; directory is restricted to SYSTEM/Administrators.'
Write-Host "Run in elevated CMD next, after all updates/reboots complete:"
Write-Host "C:\Windows\System32\Sysprep\Sysprep.exe /generalize /oobe /shutdown /unattend:`"$path`""
