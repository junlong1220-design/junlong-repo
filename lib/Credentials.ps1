# Credentials are requested once on the controller, before parallel workers start.
# Runtime values are never written back to the configuration file.
function Set-InteractiveCredentials {
    param([System.Collections.IDictionary]$Config,[ValidateSet('Aoc','Local','Domain','Horizon')][string[]]$Roles)
    foreach ($role in @('Aoc','Local','Domain','Horizon')) {
        $Config.Remove("${role}Username")
        $Config.Remove("${role}Password")
    }
    $credentials=@{}
    foreach ($role in $Roles) {
        $message=switch ($role) {
            'Aoc' {'AOC API account (use the configured AocUserSource)'}
            'Local' {'Golden template local administrator account (example: Admin)'}
            'Domain' {'AD domain account for domain join, remote installation and DNS cleanup (example: administrator@demo.com)'}
            'Horizon' {'Horizon registration account (NetBIOS format required: DEMO\administrator)'}
        }
        $credential=Get-Credential -Message $message
        if ($null -eq $credential -or [string]::IsNullOrWhiteSpace($credential.UserName) -or $credential.Password.Length -eq 0) {
            throw "Credentials are required for $role. No default or saved password is used."
        }
        $credentials[$role]=$credential
        # Usernames remain part of legacy batch compatibility checks. Passwords do not.
        $Config["${role}Username"]=$credential.UserName
    }
    return $credentials
}
function Clear-InteractiveCredentials {
    param([System.Collections.IDictionary]$Config,[System.Collections.IDictionary]$Credentials)
    if ($Config) {
        foreach ($role in @('Aoc','Local','Domain','Horizon')) {$Config.Remove("${role}Password")}
    }
    if ($Credentials) {$Credentials.Clear()}
}
