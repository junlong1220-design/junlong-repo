# Horizon Simple Deployment

Create Windows VMs from an AOC template, rename them, join them to AD, install the Horizon Agent, and verify the `wsnm` service.

## Requirements

- A Windows controller VM running elevated PowerShell 7.2 or later
- Network access from the controller VM to AOC, VM WinRM (TCP 5985), AD, and DNS
- A Windows template with VMTools, Cloudbase-inti, DHCP, and the local `Admin` account under Administrator group
- PowerShell remoting access to DNS with permission to remove the related records

Credentials for AOC, the template, AD, and Horizon are requested interactively. Never store passwords in JSON.

## 1. Prepare the Golden Image template

After Windows OS installation done, Must run windows update and keep the VM widows updated and reboot the machines. Make sure local `Admin` account is created and under `administrators` group. Allow the Remote desktop connections.

Make sure you upload the Horzion Agent installation file and Prepare-Template.ps1 to this Golden image VM. The recommended path is “C:\” . Then,Login the VM with local account `Admin` Open the Powershell and Run as administrator to execute below:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\Prepare-Template.ps1 -ControllerIP 192.168.1.50
```

Please replace the `-ControllerIP` address with your Windows controller VM address. After Run the above `Prepare-Template.ps1`, Sysprep command printed by the script. Such as:
`Run in elevated CMD next. C:\Windows\System32\Sysprep\Sysprep.exe /generalize /oobe /shutdown /unattend:"C:\ProgramData\SimpleVDI\Unattend.xml"`
Before you cmd run below commands, you can delete the PrePare-Template.ps1 Optionally this Golden iamge VM.

```CMD
C:\Windows\System32\Sysprep\Sysprep.exe /generalize /oobe /shutdown /unattend:"C:\ProgramData\SimpleVDI\Unattend.xml"
```

 shut down the template automatically, and publish it in AOC clone or convert to Template. Test one clone before starting a batch deployment.

Optionally, If you use Omnissa Horizon OS Optimization Tool (OSOT), complete optimization and cleanup first, then reboot before running this project. Use only the Sysprep command printed by this project; DO NOT run OSOT Generalize afterward and overwrite these settings.

## 2. Configure and deploy via Windows controller VM
Login with your local account and run the powershell script in your Windows controller VM 

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

### JSON Parameter Reference

| Parameter | Description |
| --- | --- |
| `AocUrl` | URL of the AOC management platform. |
| `AocUserSource` | AOC user source, for example `LOCAL`. |
| `SkipAocCertificateCheck` | Whether to skip AOC HTTPS certificate validation; use `false` in production. |
| `TemplateName` | Name of the AOC template used for cloning. |
| `ClusterName` | AOC cluster where the virtual machines are created. |
| `Prefix` | Virtual machine name prefix, for example `VDI-`. |
| `StartIndex` | Starting index for virtual machine numbering. |
| `FullCopy` | Whether to use full clones; `false` uses linked clones, subject to AOC behavior. |
| `Count` | Number of virtual machines to create in this batch. |
| `Concurrency` | Number of workers per pipeline stage. Supports `1–30` and defaults to `20`. |
| `CpuCount` | Number of vCPUs assigned to each virtual machine. |
| `MemoryGB` | Amount of memory assigned to each virtual machine, in GB. |
| `DomainName` | AD domain to join. |
| `DomainControllerIP` | IP address of the domain controller. |
| `OUPath` | OU path where AD computer accounts are created. |
| `ConnectionServer` | Horizon Connection Server address. |
| `AgentSourcePath` | Full path to the Horizon Agent EXE on the controller, for example `C:\HorizonAgent.exe`. Do not install the Agent in the source template. |
| `AgentFeatures` | Comma-separated Horizon Agent features enabled during silent installation, for example `Core,USB,RTAV`. |
| `ValidateInstallerSignature` | Whether to validate the digital signature of the Horizon Agent installer. |

AOC, template, AD, and Horizon passwords are not stored in JSON; they are entered interactively at runtime.

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
