# Horizon Simple Deployment

Create Windows VMs from an AOC template, rename them, join them to AD, install the Horizon Agent, and verify the `wsnm` service.

## Requirements

- A Windows controller running elevated PowerShell 7.2 or later
- Network access from the controller to AOC, VM WinRM (TCP 5985), AD, and DNS
- A Windows template with VMTools, DHCP, and the local `Admin` account
- PowerShell remoting access to DNS with permission to remove the related records

Credentials for AOC, the template, AD, and Horizon are requested interactively. Never store passwords in JSON.

## 1. Prepare the Golden Image template

Must run windows update and reboot the machines. after that, Sign in to the workgroup template as the local `Admin` account and open elevated PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\Prepare-Template.ps1 -ControllerIP 192.168.1.50
```

Replace the IP address with the controller address. Run the Sysprep command printed by the script, shut down the template, and publish it in AOC. Test one clone before starting a batch deployment.

If you use OSOT, complete optimization and cleanup first, then reboot before running this project. Use only the Sysprep command printed by this project; do not run OSOT Generalize afterward and overwrite these settings.

## 2. Configure and deploy

```powershell
Copy-Item .\init.example.json .\init.json
notepad .\init.json
```

Fill in the AOC, template/cluster, naming, AD, Connection Server, and Agent settings. See [init.example.json](./init.example.json) for the full example. Common batch settings:

```json
"Prefix": "VDI-",
"StartIndex": 1,
"Count": 20,
"Concurrency": 20,
"FullCopy": false
```

`AgentSourcePath` must point to an EXE directly, for example `C:\HorizonAgent.exe`. Do not install the Agent in the source template. The script installs it silently inside each clone and deletes the EXE after a successful installation.

Validate first, then deploy:

```powershell
.\Deploy.ps1 -ConfigPath .\init.json -StatePath .\batch-101.json -ValidateOnly
.\Deploy.ps1 -ConfigPath .\init.json -StatePath .\batch-101.json
```

`Concurrency` limits workers in each pipeline stage. It supports 1–30 and defaults to 20; it is not the total number of VMs active across the entire workflow. `Verified` means local checks passed. Confirm Broker registration separately in Horizon Console.

### Resume a deployment

Fix the reported cause and rerun the command with the same configuration and state files. Do not delete the state file or recreate existing VMs. CSV reports are written next to the state file.

## 3. Clean up a batch

Cleanup force-powers off the VMs, moves them to the AOC recycle bin, and removes matching A/AAAA/PTR DNS records. It does not delete AD computer accounts or Horizon Console entries.

Preview first:

```powershell
.\Cleanup.ps1 -StatePath .\batch-101.json
```

Review the VMs and DNS records, then execute:

```powershell
.\Cleanup.ps1 -StatePath .\batch-101.json -Execute
.\Cleanup.ps1 -StatePath .\batch-101.json -Names 'VDI-0001','VDI-0002' -Execute
```

Cleanup progress is stored in `batch-101.cleanup.json`. After fixing a failure, rerun the same command. Do not manually clear a phase or delete a receipt. List incomplete entries with:

```powershell
(Get-Content .\batch-101.cleanup.json -Raw | ConvertFrom-Json).Entries |
  Where-Object { $_.Error -or $_.Phase -ne 'Completed' } |
  Format-List Hostname,Phase,TaskId,Error
```

For an uncertain AOC task status, run a read-only check:

```powershell
.\Get-CleanupDiagnostics.ps1 -StatePath .\batch-101.json -Names 'VDI-0001'
```

## Troubleshooting

```powershell
# Deployment status
(Get-Content .\batch-101.json -Raw | ConvertFrom-Json).Entries |
  Where-Object { $_.Error -or $_.Phase -ne 'Verified' } |
  Format-List Hostname,Phase,IP,TaskId,Error

# AOC task, configuration, and template diagnostics
.\Get-AocTaskDiagnostics.ps1 -StatePath .\batch-101.json
.\Get-BatchConfigDiagnostics.ps1 -StatePath .\batch-101.json
.\Get-TemplateDiagnostics.ps1
```

Check the AOC task center, VM WinRM/TCP 5985, DHCP, AD/DNS, credentials, Agent path, and installation logs. A brief connection loss during reboot is expected if the VM later reaches `Verified`.

## Important rules

- Enter usernames and passwords at runtime; do not store them in JSON.
- Keep each batch's configuration, deployment state, and cleanup state files together.
- Once cleanup starts for a state file, do not deploy with it again. Use a new state path and unused names for a new batch.
- Cleanup may leave AD computer accounts behind. Review them separately before reusing names.
