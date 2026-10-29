function Get-GuestCredentialUsernames {
    param($Entry,[string]$Username,[string]$IP,[bool]$IsLocalAccount)
    if (-not $IsLocalAccount) {$Username;return}
    # A template account must be resolved against each guest, not the controller
    # or the template's old machine name. Preserve the password unchanged.
    if ($Username -match '@') {throw 'Use a local username, such as Admin, for the template account; a UPN is a domain account.'}
    $account=($Username -split '\\')[-1]
    if ([string]::IsNullOrWhiteSpace($account)) {throw 'The local template username is empty.'}
    $known=Get-AocOptionalProperty $Entry 'GuestComputerName'
    # Preserve an explicitly supplied template computer name for the first connection.
    $templateAuthority=''
    if ($Username -match '^(?<Computer>[^\\]+)\\[^\\]+$' -and $Matches.Computer -ne '.') {$templateAuthority=$Matches.Computer}
    $authorities=@($Entry.Hostname,$known,$templateAuthority,$IP) | Where-Object {$_} | Select-Object -Unique
    foreach ($authority in $authorities) {"$authority\$account"}
}
