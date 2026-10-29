$script:GuestInstall = {
    param($Installer,$Hash,$Server,$Features,[pscredential]$HorizonCredential,$Timeout,$ValidateSignature=$true)
    $ErrorActionPreference='Stop'
    if ($HorizonCredential.UserName -notmatch '^[^\\@\s"\r\n]+\\[^\\@\s"\r\n]+$') {
        throw 'Agent registration requires AD NetBIOS domain\username.'
    }
    $directory='C:\ProgramData\VDIDeploy' 
    $resultPath=Join-Path $directory 'install-result.json'
    if ($Hash -and (Get-FileHash $Installer -Algorithm SHA256).Hash -ine $Hash) { throw 'Guest installer checksum mismatch.' }
    if (Test-Path $resultPath) {
        $previous=Get-Content $resultPath -Raw | ConvertFrom-Json
        if ($previous.Hash -ine $Hash -or $previous.Server -ine $Server -or $previous.Features -ne $Features) {
            throw 'Previous install receipt does not match this deployment.'
        }
        if ($previous.ExitCode -in @(0,3010)) { return $previous }
    }
    if (-not (Test-Path -LiteralPath $Installer -PathType Leaf)) {throw "Preloaded Agent installer is missing: $Installer"}
    if ($ValidateSignature -and (Get-AuthenticodeSignature -FilePath $Installer).Status -ne 'Valid') {throw 'Guest installer signature is invalid.'}
    $existing=@(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like '*Horizon Agent*' })
    if ($existing.Count -gt 0 -and -not (Test-Path $resultPath)) {
        throw 'Horizon Agent is already installed without a deployment receipt. Inspect it before retrying.'
    }
    # Do not run a second installer if a previous remote session disconnected while installation was in progress.
    if (Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Installer)) -ErrorAction SilentlyContinue) {
        throw 'Agent installer is still running; wait and resume.'
    }
    $settings=Join-Path $directory 'agent-settings.txt'
    $values=@('VDM_VC_MANAGED_AGENT=0','VDM_PAIRING_MECHANISM=1',"VDM_SERVER_NAME=$Server",
        "VDM_SERVER_USERNAME=$($HorizonCredential.UserName)",'VDM_IP_PROTOCOL_USAGE=IPv4',
        'REBOOT=ReallySuppress',"ADDLOCAL=$Features")
    [IO.File]::WriteAllLines($settings,[string[]]$values,[Text.UTF8Encoding]::new($false))
    $password=$HorizonCredential.GetNetworkCredential().Password
    # This is passed directly to the EXE, never cmd.exe. !, &, $, and spaces are not shell-expanded.
    # Embedded quotes/newlines are rejected rather than silently mangled by nested EXE/MSI quoting.
    if ($password -match '["\r\n]' -or $password.EndsWith('\')) {
        throw 'Registration password contains unsupported nested-command quoting characters.'
    }
    # Match the vendor's documented command for passwords without whitespace.
    # Keep escaped inner quotes only when the MSI property needs whitespace quoting.
    $passwordProperty=$password
    if ($password -match '\s') {$passwordProperty='\"'+$password+'\"'}
    $args='/s /v "/qn SETTINGS_FILE=C:\ProgramData\VDIDeploy\agent-settings.txt VDM_SERVER_PASSWORD=' + $passwordProperty + '"' 
    $boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
    $start=New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName=$Installer; $start.Arguments=$args; $start.UseShellExecute=$false
    $process=New-Object System.Diagnostics.Process
    $process.StartInfo=$start
    try {
        $null=$process.Start()
        if (-not $process.WaitForExit([int]$Timeout*1000)) {
            throw 'Agent installation timed out. Installer was left running; inspect it before retrying.'
        }
        $result=[pscustomobject]@{Hash=$Hash;Server=$Server;Features=$Features;ExitCode=$process.ExitCode;Boot=$boot}
        $result | ConvertTo-Json | Set-Content $resultPath -Encoding UTF8
        if ($process.ExitCode -notin @(0,3010)) { throw "Agent installation failed with exit code $($process.ExitCode)." }
        return $result
    } finally {
        $start.Arguments=''; $args=$null; $passwordProperty=$null; $password=$null
        Remove-Item $settings -Force -ErrorAction SilentlyContinue
        $process.Dispose()
    }
}

$script:GuestVerify = {
    param($TargetName,$DomainName,$DisableFirewall)
    $ErrorActionPreference='Stop'
    $cs=Get-CimInstance Win32_ComputerSystem
    if ($env:COMPUTERNAME -ine $TargetName -or -not $cs.PartOfDomain -or $cs.Domain -ine $DomainName) {
        throw 'Final hostname/domain validation failed.'
    }
    if (-not (Test-ComputerSecureChannel)) { throw 'Final AD secure channel validation failed.' }
    if ($DisableFirewall -and @(Get-NetFirewallProfile | Where-Object Enabled -eq True).Count -gt 0) {
        throw 'Firewall was re-enabled, possibly by domain GPO.'
    }
    # Service health is the acceptance criterion; no version or uninstall-entry check.
    try {$service=Get-Service -Name 'wsnm' -ErrorAction Stop}
    catch {throw 'Horizon Agent service wsnm was not found or could not be queried.'}
    if ($service.Status -ne 'Running') {
        Write-Host 'Waiting up to 180 seconds for Horizon Agent service wsnm to reach Running.'
        try {$service.WaitForStatus('Running',[TimeSpan]::FromSeconds(180))}
        catch {throw 'Horizon Agent service wsnm did not reach Running within 180 seconds after reboot. Inspect Agent logs and Windows service events.'}
    }
    $service.Refresh()
    if ($service.Status -ne 'Running') {throw 'Horizon Agent service wsnm is not running after the startup wait.'}
    [pscustomobject]@{Name=$env:COMPUTERNAME;Domain=$cs.Domain;Service=$service.Status.ToString()}
}

# Runs only after successful installation, reboot and service verification.
$script:GuestCleanupAgent={
    param([string]$Installer)
    $ErrorActionPreference='Stop'
    if ($Installer -notmatch '^C:\\[^\\/:*?"<>|]+\.exe$') {throw 'Unsafe guest installer cleanup path.'}
    if (Test-Path -LiteralPath $Installer) {Remove-Item -LiteralPath $Installer -Force}
    # Delete C: recycle-bin contents for all profiles. Windows recreates the bin.
    $bin='C:\$Recycle.Bin'
    if (Test-Path -LiteralPath $bin) {Remove-Item -LiteralPath $bin -Recurse -Force -ErrorAction Stop}
    if (Test-Path -LiteralPath $Installer) {throw 'Agent installer cleanup did not finish.'}
}
