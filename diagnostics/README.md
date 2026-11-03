# Diagnostics

Diagnostic scripts are grouped here; deployment and template preparation remain in the project root. Existing diagnostic commands must now include the `diagnostics\` directory. Script parameters and diagnostic behavior are unchanged.

| Script | Run on | PowerShell | Purpose |
| --- | --- | --- | --- |
| [Get-AocTaskDiagnostics.ps1](./Get-AocTaskDiagnostics.ps1) | Controller | 7.2+ | Inspect saved AOC tasks and VM status |
| [Get-BatchConfigDiagnostics.ps1](./Get-BatchConfigDiagnostics.ps1) | Controller | 7.2+ | Compare batch configuration and state |
| [Get-CleanupDiagnostics.ps1](./Get-CleanupDiagnostics.ps1) | Controller | 7.2+ | Inspect cleanup state and receipts |
| [Get-TemplateDiagnostics.ps1](./Get-TemplateDiagnostics.ps1) | Template or failed clone, elevated | 5.1+ | Inspect WinRM, accounts, policy and failed logons |
| [Get-LogonDiagnostics.ps1](./Get-LogonDiagnostics.ps1) | Affected Windows VM, elevated | 5.1+ | Inspect DNS, AD, time and logon events |

From the project root on the Controller:

```powershell
.\diagnostics\Get-AocTaskDiagnostics.ps1 -StatePath .\batch-101.json -Limit 3
.\diagnostics\Get-BatchConfigDiagnostics.ps1 -StatePath .\batch-101.json
.\diagnostics\Get-CleanupDiagnostics.ps1 -StatePath .\batch-101.json -Names 'vm-0001'
```

Controller scripts load libraries from `../lib` and default to `../init.json`, independent of the current directory. Explicit relative `-ConfigPath` and `-StatePath` values still resolve against the current PowerShell location. Keep the project directory structure when copying Controller diagnostics.

The two Windows VM scripts have no project library dependencies. Copy the required script into the VM and run it in elevated Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Get-TemplateDiagnostics.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Get-LogonDiagnostics.ps1 -Minutes 30
```
