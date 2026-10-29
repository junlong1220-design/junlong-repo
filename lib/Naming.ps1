function Get-DeploymentNames {
    param([hashtable]$Config)
    $hasList=$Config.ContainsKey('Hostnames') -and $null -ne $Config.Hostnames -and @($Config.Hostnames).Count -gt 0
    $hasPrefix=$Config.ContainsKey('Prefix') -and -not [string]::IsNullOrWhiteSpace([string]$Config.Prefix)
    if ($hasList -and $hasPrefix) {throw 'Use Prefix/StartIndex/Count OR Hostnames. Remove Hostnames when using Prefix.'}
    if ($hasList) {
        if ($Config.Hostnames -isnot [array]) {throw 'Hostnames must be a JSON array.'}
        $names=@($Config.Hostnames)
    } else {
        if (-not $hasPrefix) {throw 'Specify Prefix and StartIndex/Count, or a Hostnames array.'}
        foreach ($key in @('StartIndex','Count')) {
            $parsed=0L
            if (-not $Config.ContainsKey($key) -or -not [long]::TryParse([string]$Config[$key],[ref]$parsed)) {throw "$key must be an integer."}
        }
        $start=[long]$Config.StartIndex;$count=[long]$Config.Count
        if ($start -lt 0 -or $start -gt [int]::MaxValue -or $count -lt 1 -or $count -gt 1000 -or $start+$count-1 -gt [int]::MaxValue) {throw 'StartIndex must be >=0; Count must be 1..1000; last index must fit Int32.'}
        # Minimum numeric width is built in; D4 automatically expands beyond 9999.
        # Preserve explicit legacy widths to avoid renaming existing batches.
        $width=4
        if ($Config.ContainsKey('IndexWidth')) {
            if (-not [int]::TryParse([string]$Config.IndexWidth,[ref]$width) -or $width -lt 1 -or $width -gt 10) {throw 'IndexWidth must be an integer from 1 to 10.'}
        }
        $names=@(for ($index=0L;$index -lt $count;$index++) {([string]$Config.Prefix)+($start+$index).ToString("D$width",[Globalization.CultureInfo]::InvariantCulture)})
    }
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $names) {
        if ($name -isnot [string] -or $name.Length -gt 15 -or $name -notmatch '^[A-Za-z][A-Za-z0-9-]*[A-Za-z0-9]$') {throw "Invalid Windows hostname: $name (max 15 characters)."}
        if (-not $seen.Add($name)) {throw "Duplicate hostname: $name"}
        $name
    }
}
