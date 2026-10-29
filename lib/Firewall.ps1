$script:GuestDisableFirewall = {
    $ErrorActionPreference='Stop'
    # Keep the Windows Firewall service running; disable all three profiles.
    Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled False -ErrorAction Stop
    $profiles=@(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop)
    foreach ($name in @('Domain','Private','Public')) {
        $profile=@($profiles | Where-Object {$_.Name -eq $name})
        if ($profile.Count -ne 1 -or [string]$profile[0].Enabled -ne 'False') {
            throw "Windows Firewall profile $name remains enabled or cannot be verified. Check domain Group Policy."
        }
    }
    $profiles | Select-Object Name,Enabled
}
