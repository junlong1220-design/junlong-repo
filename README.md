# Horizon Simple Deployment

Create Windows guest VMs from an AOC template, obtain DHCP addresses, rename and reboot, join AD and reboot, silently install Horizon Agent, reboot, and verify the `wsnm` service. Confirm broker registration separately in Horizon Console.

## Requirements

- A Windows controller machine for running this script with elevated PowerShell 7.2 or later.
- Network access to Arcfra Operation Center, guest OS WinRM on TCP 5985, Active Directory, and the Horizon Connection Server.
- A golden image template with VMTools, Cloudbase-Init, DHCP, and a local `Admin` account in the `Administrators` group.
- AD DNS reachable through PowerShell remoting, with the `DNS Server` module and an account authorized to delete DNS records for cleanup.

Usernames and passwords are requested interactively. Do not store them in JSON. The template account is local (for example, `Admin`); the domain account can be entered as `administrator@demo.com`; the Horizon registration account must use the `DEMO\administrator` format.

## 1. Prepare the Golden Image Template

1. Install Windows through AOC and make sure the local `Admin` account exists and belongs to the `Administrators` group.
2. Log in with the local `Admin` account, install all Windows updates, and complete any required reboots.
3. Optional: upload and run Omnissa OS Optimization Tool (OSOT) for optimization and cleanup. Remove the installation package and reboot when finished.
4. Upload the Horizon Agent EXE, [Prepare-Template.cmd](./Prepare-Template.cmd), and [Prepare-Template.ps1](./Prepare-Template.ps1) to the source VM, for example under `C:\`. Copy the Horizon Agent EXE to `C:\HorizonAgent.exe` but do not install it. Keep [Prepare-Template.cmd](./Prepare-Template.cmd) beside [Prepare-Template.ps1](./Prepare-Template.ps1).
5. Double-click the [Prepare-Template.cmd](./Prepare-Template.cmd) launcher, accept the UAC prompt, and enter the local `Admin` password. Preparation runs Sysprep automatically and shuts down the VM. If an error occurs, the PowerShell window remains open for inspection.
6. Convert the VM into an AOC VM template. Set the template name and make sure the VM Initialization Tool is installed and enabled.

Alternatively, open elevated PowerShell and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Prepare-Template.ps1
```

The launch command applies `Bypass` only to the new PowerShell process, so no separate `Set-ExecutionPolicy` command or persistent policy change is needed. Execution policy enforced by Group Policy still takes precedence. Setting the policy inside the script cannot help if execution is blocked before the script starts.

The script configures the local account, DHCP, WinRM bootstrap, first-logon privacy settings, and the unattended setup (English by default). WinRM TCP 5985 accepts connections from any source IP on all network profiles; authentication is still required. Enter the same local password later during deployment. The preparation script does not check the Agent installer; deployment validates it inside each clone.

The script automatically runs Sysprep with its custom answer file. After Sysprep succeeds, it deletes the running copy of `Prepare-Template.ps1` and the companion `Prepare-Template.cmd` in the same directory, then shuts down Windows. Do not rerun template preparation or publish the VM until this cleanup has completed.


## 2. Configure and deploy

Run this script on the Windows controller. For a new setup:

```powershell
Copy-Item .\init.example.json .\init.json
notepad .\init.json
```

For an existing setup, keep your current `init.json` and state files when updating scripts.

Set the AOC URL and account source, template and cluster names, AD domain/DNS address, optional OU, Connection Server, installer path, VM resources, and naming settings:

```json
"VMNamePrefix": "vm-",
"StartIndex": 1,
"Count": 30,
"FullCopy": false,
"Concurrency": 20
```

The example creates 30 VMs. A single `Concurrency: 20` setting limits each pipeline stage to 20 workers.

This example is a fragment of `init.json`. Names start at `vm-0001`. Numeric suffixes use at least four digits and grow automatically. Complete Windows hostnames must fit within 15 characters. Use JSON boolean `false` for non-full-copy clones.

`VMNamePrefix` is shared by the AOC VM display name and the Windows hostname: `VDI-` with `StartIndex: 1` generates `VDI-0001`, `VDI-0002`, and so on. The old `Prefix` key remains supported. Renaming only the key to `VMNamePrefix` with the same value preserves saved batch compatibility; changing the prefix value changes VM names. If both keys are present, their values must match exactly. Use either prefix-based naming or an explicit `Hostnames` array.

| Setting | Meaning |
|---|---|
| `AocUrl` | HTTPS URL of the Arcfra Operation Center (AOC) to use for deployment |
| `AocUserSource` | AOC authentication source sent during login; `LOCAL` uses local AOC users |
| `SkipAocCertificateCheck` | When `true`, skips AOC TLS certificate validation; use only when required by the environment, because it reduces connection security |
| `TemplateName` | Name of the prepared Windows VM template in AOC |
| `ClusterName` | Name of the target AOC cluster where the VMs will be created |
| `VMNamePrefix` | Shared prefix for the AOC VM display name and Windows hostname; followed by the numeric index |
| `FullCopy` | Whether to use full-copy cloning; `true` creates independent full copies, while `false` uses linked-clone behavior where supported |
| `StartIndex` | Starting number for VM naming; `1` generates the first VM as `vm-0001` |
| `Count` | Total VMs in the batch |
| `Concurrency` | Unified per-stage worker limit; default 20, recommended 20 or less, supported range 1..30 |
| `CpuCount` | Number of virtual CPUs assigned to each VM |
| `MemoryGB` | Amount of memory, in GB, assigned to each VM |
| `DomainName` | Active Directory domain that each VM joins, such as `vdi-demo.com` |
| `DomainControllerIP` | IP address of the domain controller/DNS server used for DNS operations and domain joining |
| `OUPath` | Optional distinguished name of the AD organizational unit for new computer accounts, such as `OU=VDI,DC=vdi-demo,DC=com` |
| `ConnectionServer` | Hostname or IP address of the Horizon Connection Server used for Agent registration |
| `AgentSourcePath` | Path inside the golden template to the Horizon Agent EXE; it must be directly under `C:\`, for example `C:\HorizonAgent.exe` |
| `AgentFeatures` | Comma-separated Horizon Agent feature list passed to the installer, such as `Core,USB,RTAV` |
| `ValidateInstallerSignature` | When `true`, verifies the Horizon Agent installer signature before installation |


Validate, then deploy:

`batch-101.json` is the deployment state file for this batch. The script creates it to record the VM names and IDs, IP addresses, current workflow phase, task results and verification status. Keeping this file allows a failed or interrupted deployment to resume safely, and it also gives `Cleanup.ps1` the exact batch scope to preview or remove. The CSV report generated next to it is for review; the JSON state file is the source of truth for resume and cleanup.

```powershell
.\Deploy.ps1 -ConfigPath .\init.json -StatePath .\batch-101.json -ValidateOnly
.\Deploy.ps1 -ConfigPath .\init.json -StatePath .\batch-101.json
```

Enter AOC, template local administrator, AD, and Horizon credentials when prompted. Prompts run once per invocation, before parallel workers start. For an existing batch, keep usernames and their format consistent. Validation does not create guests or prove the full template workflow.

To resume after fixing an error, rerun the same command with the same configuration and state file. Do not delete state or recreate existing VMs. To start a new batch, manually change `-StatePath` to a new unused filename, such as `batch-102.json`, before running the command; do not reuse an existing batch file or overwrite its history. Review the CSV reports next to the state file. A `Verified` VM has passed local service checks; verify registration in Horizon Console.

## 3. Cleanup: preview, execute and resume

Cleanup forcibly powers off selected batch VMs, moves them to the AOC recycle bin, and deletes matching forward A/AAAA and reverse PTR DNS records. It does not permanently delete VMs, AD computer accounts, or Horizon Console entries. Forced power-off interrupts running workloads. Restoring a recycled VM may require DNS re-registration.

### Step 1: select the correct batch

Use elevated PowerShell 7.2+ on the controller, open the project directory, and identify the deployment state for the batch to remove. Keep `init.json` pointed at the correct AOC, cluster and DNS domain. Stop deployment before cleanup.

### Step 2: preview

```powershell
.\Cleanup.ps1 -StatePath 'C:\horizon-simple\batch-101.json'
```

Enter AOC and AD credentials. Review the VM names/IDs and DNS records. Without `-Execute`, no VM or DNS changes are made. Preview may temporarily update controller TrustedHosts for DNS remoting and restores it afterward.

### Step 3: execute

```powershell
.\Cleanup.ps1 -StatePath 'C:\horizon-simple\batch-101.json' -Execute
```

To clean only selected VMs from that batch:

```powershell
.\Cleanup.ps1 -StatePath .\batch-101.json -Names 'vm-0001','vm-0002' -Execute
```

The script verifies saved VM IDs, ownership tags, cluster, and active VM names. AOC recycle-bin names are accepted only with confirmed recycle state and matching identity. DNS uses the original batch hostnames, not recycle-bin names.

### Step 4: check completion

Successful entries show `recycled; matching DNS records removed`. Progress is saved separately in `batch-101.cleanup.json`; keep it together with `batch-101.json`.

To list incomplete entries:

```powershell
(Get-Content .\batch-101.cleanup.json -Raw | ConvertFrom-Json).Entries |
    Where-Object { $_.Error -or $_.Phase -ne 'Completed' } |
    Format-List Hostname,Phase,TaskId,Error
```

### Step 5: resume if needed

Fix the reported cause and rerun the same cleanup command. Already recycled VMs can continue DNS cleanup without another recycle request.
For uncertain results, inspect AOC without changing VMs/DNS/state:

```powershell
.\diagnostics\Get-CleanupDiagnostics.ps1 -StatePath .\batch-101.json -Names 'vm-0001'
```

If `RecyclePending` has no task ID, automatic resubmission is blocked. Check AOC task center. If the VM is stopped and no recycle task is active, manually move it to the recycle bin, then rerun cleanup. Do not blindly clear its phase or delete the receipt.

If a state save reports access denied, check permissions, read-only attributes and processes holding the reported file. The scripts retry transient file errors; persistent failures need investigation. Do not automatically adopt temporary snapshots as state.

Once cleanup starts, deployment with that state is blocked. For new deployments, use a new state path and unused names. AD computer accounts remain and may need separate administrative review before names are reused.

## Troubleshooting deployment

List failed or incomplete entries:

```powershell
(Get-Content .\batch-101.json -Raw | ConvertFrom-Json).Entries |
    Where-Object { $_.Error -or $_.Phase -ne 'Verified' } |
    Format-List Hostname,Phase,IP,TaskId,Error
```

Check current AOC power status/IP, guest boot/OOBE, TCP 5985, credentials and installer logs according to the error. Temporary connection loss during reboot is expected if the VM subsequently reaches `Verified`.

For `Starting` without a task ID, inspect AOC task center. If stopped with no active start task, manually power on the VM and resume. The script verifies identity and `RUNNING` state before continuing; it does not resubmit an uncertain start request.

All five diagnostic scripts are in [diagnostics](./diagnostics/README.md), with usage examples and runtime requirements. Run Controller diagnostics from the project root, for example:

```powershell
.\diagnostics\Get-AocTaskDiagnostics.ps1 -StatePath .\batch-101.json
```

Configuration reconciliation is available through `-ReconcileConfig -ValidateOnly` for review, followed by `-ReconcileConfig` when the saved batch is eligible. Do not use it to bypass VM ownership or naming mismatches.

## Preloaded Agent installer

Before sealing the golden template, copy the Horizon Agent EXE to `C:\HorizonAgent.exe` (or another EXE directly under `C:\`). Do not install it in the source image. Set `AgentSourcePath` in `init.json` to `"C:\\HorizonAgent.exe"`. This path now refers to the guest, not the controller. UNC/network installer transfer is no longer used. The installer remains on the source template for future clones.

After domain join, the script uses the domain remote session to run the preloaded EXE silently, without a separate installation concurrency limit. Signature validation runs inside each VM. After successful installation, reboot and `wsnm` service verification, the script permanently deletes exactly that EXE and removes `C:\$Recycle.Bin` for all local profiles. Windows recreates the recycle bin. This clears all C: recycled items, not just the installer. Installation failures retain the package for troubleshooting. A cleanup failure keeps the VM incomplete and reports the error, so the same state can be resumed without reinstalling a successfully receipted Agent. Do not remove the Windows Installer or Omnissa InstallerCache directories.

### Unified concurrency

Only `Count` and `Concurrency` are needed for batch scheduling. `Count: 30` creates 30 VMs. `Concurrency: 20` allows up to 20 clone/start workers and up to 20 guest workflow workers. The pools are independent and overlap, so this is a per-stage limit, not a maximum of 20 active VMs across the entire pipeline. A guest worker starts its local Agent installation as soon as it is ready, without a separate installation gate. VMs do not start or install at the same instant.

Default concurrency is 20, with 20 or less recommended. The supported range is 1..30. For `Count: 30` and `Concurrency: 30`, each stage may use up to 30 workers, subject to platform capacity. This is a script setting, not an Arcfra API limit. Validate higher values against task queues, storage load and Windows boot times. `Concurrency: 1` uses serial execution.


## Templates optimized with Omnissa OSOT

Official OSOT guidance separates Optimize, Generalize and Finalize. Generalize runs Sysprep and supports a custom answer file. Finalize may clear the Default profile and create local group policies. See [OSOT image workflow](https://docs.omnissa.com/Optimizing-Images-for-Horizon/building-an-image-with-osot) and [command-line operations](https://docs.omnissa.com/Optimizing-Images-for-Horizon/RunWindowsOSOptimizationToolforHorizonfromCommandLine).

Our external AOC workflow intentionally installs Agent after cloning, unlike the standard Horizon image guide. Complete your selected OSOT optimization/cleanup before running this project's preparation script, reboot if needed, then run `Prepare-Template.cmd`. It automatically runs Sysprep with its custom answer file unless `-PrepareOnly` is specified. Do not subsequently run OSOT Generalize with its default answer file or rerun Optimize/Finalize after preparation, as these may replace our settings. This is an adaptation for this script, not a claim to reproduce the standard Horizon Instant Clone workflow.

Preparation checks for conflicting WinRM authentication settings, checks local Admin group membership without suppressing errors, and tests local Admin authentication to the remoting endpoint before proceeding. Policy conflicts cause a clear failure rather than a falsely successful template. It does not disable NTLM restrictions or remove deny-logon security policy blindly.

Before initial rename, the Windows computer name may still be the source template's name. At the template local credential prompt, you may enter `TEMPLATECOMPUTER\Admin` using the actual template hostname. The connector now preserves that qualifier as a fallback, while prioritizing the target name after rename. UUID validation remains mandatory. Older versions discarded the supplied computer qualifier, which could make initial authentication fail even with a correct explicit local username.

For existing failed clones, run `diagnostics\Get-TemplateDiagnostics.ps1` elevated inside one clone and inspect Security 4625 status/substatus, local account membership, effective network logon rights, NTLM restrictions and WinRM Negotiate policy. This script is standalone and can be copied into the clone on its own. Running OSOT alone does not establish that OSOT disabled WinRM or changed passwords. Preserve the OSOT selection/export/history and collect the failed-clone diagnostics before attributing the failure to a specific optimization. Validate one fully generalized clone before batch deployment.

Template preparation preserves Public/Private/Domain network categories. It enables remoting with `-SkipNetworkProfileCheck` and does not issue additional WinRM configuration-provider writes. Registry-based read-only checks reject explicit conflicts with Negotiate=true, Basic=false and AllowUnencrypted=false, using Windows defaults for absent settings. These checks are not a complete effective-policy audit; the script additionally tests a real local Admin PowerShell session. The custom TCP 5985 firewall rule permits any source IP on all profiles, with authentication still required. The startup task uses the same bootstrap. If an explicit policy conflicts, preparation stops for review rather than silently changing security policy.
