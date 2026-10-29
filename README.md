# Horizon Simple Deployment

Create Windows VMs from an AOC template, obtain DHCP addresses, rename and reboot, join AD and reboot, silently install Horizon Agent, reboot, and verify the `wsnm` service. Confirm broker registration separately in Horizon Console.

## Requirements

- Windows controller with elevated PowerShell 7.2 or later.
- Network access to AOC, guest WinRM TCP 5985, AD and AD.
- Golden template with VMTools, DHCP and the local `Admin` account.
- AD DNS reachable through PowerShell remoting, with the `DnsServer` module and an account authorized to delete DNS records for cleanup.

Usernames and passwords are requested interactively. Do not store them in JSON. The template account is local (for example, `Admin`); the domain account can use `administrator@demo.com`; the Horizon registration account must use `DEMO\administrator`.

## 1. Prepare the golden template

Complete updates and required reboots. Sign in to the workgroup template as local `Admin`, open elevated PowerShell, and run:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\Prepare-Template.ps1 -ControllerIP 192.168.1.50
```

Replace the IP with the controller's actual address. The script configures the local account, DHCP, WinRM bootstrap, first-logon privacy settings and English unattended setup. Enter the same local password later during deployment.

Run the Sysprep command printed by the script. After shutdown, keep the sealed source powered off and publish the template in AOC. Validate one clone before deploying a batch. The data-export notification workaround is version-dependent and must be checked on the clone; it does not disable data transfer.

## 2. Configure and deploy

For a new setup:

```powershell
Copy-Item .\init.example.json .\init.json
notepad .\init.json
```

For an existing setup, keep your current `init.json` and state files when updating scripts.

Set the AOC URL/account source, template and cluster names, AD domain/DNS address, optional OU, Connection Server, installer path, VM resources and naming:

```json
"Prefix": "vm-",
"StartIndex": 1,
"Count": 30,
"FullCopy": false,
"Concurrency": 20
```

The example creates 30 VMs. A single `Concurrency: 20` setting limits each pipeline stage to 20 workers.

This example is a fragment of `init.json`. Names start at `vm-0001`. Numeric suffixes use at least four digits and grow automatically. Complete Windows hostnames must fit within 15 characters. Use JSON boolean `false` for non-full-copy clones.

| Setting | Meaning |
|---|---|
| `Count` | Total VMs in the batch |
| `Concurrency` | Unified per-stage worker limit; default 20, recommended 20 or less, supported range 1..30 |

Timing defaults are built into the code: task/ordinary connection wait 900 seconds, installer wait 1800 seconds, polling 3 seconds, and reboot reconnection wait 600 seconds. Old JSON timing fields still override defaults. These are maximum waits, not fixed delays.

Validate, then deploy:

```powershell
.\Deploy.ps1 -ConfigPath .\init.json -StatePath .\batch-101.json -ValidateOnly
.\Deploy.ps1 -ConfigPath .\init.json -StatePath .\batch-101.json
```

Enter AOC, template local administrator, AD and Horizon credentials when prompted. Prompts run once per invocation, before parallel workers start. For an existing batch, keep usernames and their format consistent. Validation does not create guests or prove the full template workflow.

To resume after fixing an error, rerun the same command with the same configuration and state file. Do not delete state or recreate existing VMs. Review the CSV reports next to the state file. A `Verified` VM has passed local service checks; verify registration in Horizon Console.

## 3. Cleanup: preview, execute and resume

Cleanup force powers off selected batch VMs, moves them to the AOC recycle bin, and deletes matching forward A/AAAA and reverse PTR DNS records. It does not permanently delete VMs, AD computer accounts or Horizon Console entries. Force power off interrupts running workloads. Restoring a recycled VM may require DNS re-registration.

### Step 1: select the correct batch

Use elevated PowerShell 7.2+ on the controller, open the project directory, and identify the deployment state for the batch to remove. Keep `init.json` pointed at the correct AOC, cluster and DNS domain. Stop deployment before cleanup.

### Step 2: preview

```powershell
.\Cleanup.ps1 -StatePath 'C:\Users\Administrator\Desktop\horizon-simple\batch-101.json'
```

Enter AOC and AD credentials. Review the VM names/IDs and DNS records. Without `-Execute`, no VM or DNS changes are made. Preview may temporarily update controller TrustedHosts for DNS remoting and restores it afterward.

### Step 3: execute

```powershell
.\Cleanup.ps1 -StatePath 'C:\Users\Administrator\Desktop\horizon-simple\batch-101.json' -Execute
```

To clean only selected VMs from that batch:

```powershell
.\Cleanup.ps1 -StatePath .\batch-101.json -Names 'vm-0001','vm-0002' -Execute
```

The script verifies saved VM IDs, ownership tags and cluster, with exact active VM names. AOC recycle-bin names are accepted only with confirmed recycle state and matching identity. DNS uses original batch hostnames, not recycle-bin names.

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
.\Get-CleanupDiagnostics.ps1 -StatePath .\batch-101.json -Names 'vm-0001'
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

Additional diagnostics: `Get-AocTaskDiagnostics.ps1`, `Get-BatchConfigDiagnostics.ps1`, and `Get-LogonDiagnostics.ps1`. Configuration reconciliation is available through `-ReconcileConfig -ValidateOnly` for review, followed by `-ReconcileConfig` when the saved batch is eligible. Do not use it to bypass VM ownership or naming mismatches.

## Preloaded Agent installer

Before sealing the golden template, copy the Horizon Agent EXE to `C:\HorizonAgent.exe` (or another EXE directly under `C:\`). Do not install it in the source image. Set `AgentSourcePath` in `init.json` to `"C:\\HorizonAgent.exe"`. This path now refers to the guest, not the controller. UNC/network installer transfer is no longer used. The installer remains on the source template for future clones.

After domain join, the script uses the domain remote session to run the preloaded EXE silently, without a separate installation concurrency limit. Signature validation runs inside each VM. After successful installation, reboot and `wsnm` service verification, the script permanently deletes exactly that EXE and removes `C:\$Recycle.Bin` for all local profiles. Windows recreates the recycle bin. This clears all C: recycled items, not just the installer. Installation failures retain the package for troubleshooting. A cleanup failure keeps the VM incomplete and reports the error, so the same state can be resumed without reinstalling a successfully receipted Agent. Do not remove the Windows Installer or Omnissa InstallerCache directories.

`TransferConcurrency` and `InstallConcurrency` are no longer used. Remove both from JSON and command-line invocations. Legacy JSON fields are ignored and excluded from the batch hash, so removing them does not change batch compatibility. `-ValidateOnly` cannot inspect an offline template's guest filesystem. Validate one clone before a batch. Changing an existing batch's installer path can trigger configuration protection; use the reconciliation review where eligible, or use a new batch and unused names.

### Unified concurrency

Only `Count` and `Concurrency` are needed for batch scheduling. `Count: 30` creates 30 VMs. `Concurrency: 20` allows up to 20 clone/start workers and up to 20 guest workflow workers. The pools are independent and overlap, so this is a per-stage limit, not a maximum of 20 active VMs across the entire pipeline. A guest worker starts its local Agent installation as soon as it is ready, without a separate installation gate. VMs do not start or install at the same instant.

Default concurrency is 20, with 20 or less recommended. The supported range is 1..30. For `Count: 30` and `Concurrency: 30`, each stage may use up to 30 workers, subject to platform capacity. This is a script setting, not an Arcfra API limit. Validate higher values against task queues, storage load and Windows boot times. `Concurrency: 1` uses serial execution.

Remove `CloneConcurrency`, `TransferConcurrency` and `InstallConcurrency` from JSON. Old JSON values are ignored. Old command-line stage-specific arguments are no longer supported. Only `-Concurrency` overrides JSON. Removing these runtime fields does not change the current batch hash. Existing state and ownership protections remain in effect.

## Templates optimized with Omnissa OSOT

Official OSOT guidance separates Optimize, Generalize and Finalize. Generalize runs Sysprep and supports a custom answer file. Finalize may clear the Default profile and create local group policies. See [OSOT image workflow](https://docs.omnissa.com/Optimizing-Images-for-Horizon/building-an-image-with-osot) and [command-line operations](https://docs.omnissa.com/Optimizing-Images-for-Horizon/RunWindowsOSOptimizationToolforHorizonfromCommandLine).

Our external AOC workflow intentionally installs Agent after cloning, unlike the standard Horizon image guide. Complete your selected OSOT optimization/cleanup before running this project's preparation script, reboot if needed, then run `Prepare-Template.ps1`. Use only its printed custom-answer-file Sysprep command for the final generalization. Do not subsequently run OSOT Generalize with its default answer file or rerun Optimize/Finalize after preparation, as these may replace our settings. This is an adaptation for this script, not a claim to reproduce the standard Horizon Instant Clone workflow.

Preparation checks for conflicting WinRM authentication settings, checks local Admin group membership without suppressing errors, and tests local Admin authentication to the remoting endpoint before proceeding. Policy conflicts cause a clear failure rather than a falsely successful template. It does not disable NTLM restrictions or remove deny-logon security policy blindly.

Before initial rename, the Windows computer name may still be the source template's name. At the template local credential prompt, you may enter `TEMPLATECOMPUTER\Admin` using the actual template hostname. The connector now preserves that qualifier as a fallback, while prioritizing the target name after rename. UUID validation remains mandatory. Older versions discarded the supplied computer qualifier, which could make initial authentication fail even with a correct explicit local username.

For existing failed clones, run `Get-TemplateDiagnostics.ps1` elevated inside one clone and inspect Security 4625 status/substatus, local account membership, effective network logon rights, NTLM restrictions and WinRM Negotiate policy. Running OSOT alone does not establish that OSOT disabled WinRM or changed passwords. Preserve the OSOT selection/export/history and collect the failed-clone diagnostics before attributing the failure to a specific optimization. Validate one fully generalized clone before batch deployment.

Template preparation preserves Public/Private/Domain network categories. It enables remoting with `-SkipNetworkProfileCheck` and does not issue additional WinRM configuration-provider writes. Registry-based read-only checks reject explicit conflicts with Negotiate=true, Basic=false and AllowUnencrypted=false, using Windows defaults for absent settings. These checks are not a complete effective-policy audit; the script additionally tests a real local Admin PowerShell session. The custom TCP 5985 firewall rule permits `ControllerIP` on all profiles. The startup task uses the same bootstrap. If an explicit policy conflicts, preparation stops for review rather than silently changing security policy.

## Parallel cleanup

Cleanup reuses `Concurrency` from `init.json` (default 20, range 1..30). An explicit `Cleanup.ps1 -Concurrency` overrides JSON. Up to that many VM workflows submit force-poweroff, wait for their own task, then recycle and verify the same VM concurrently. Each VM retains its own task ID and phase. There is no single bulk API request and no guarantee all VMs switch off at the same instant.

DNS deletion follows successful recycle verification and uses one server session sequentially. Preview, all-selection ownership checks, batch locking, uncertain-submission guards and same-state resume remain in place. Parallel workers merge private receipt rows under a shared lock with atomic file saves. A failed VM does not trigger DNS deletion or cancel cleanup of other VMs.

```powershell
.\Cleanup.ps1 -StatePath .\batch-101.json -Execute
.\Cleanup.ps1 -StatePath .\batch-101.json -Execute -Concurrency 10
```

Use `-Concurrency 1` for serial cleanup. Preserve the deployment state and cleanup receipt when upgrading. Actual speed depends on AOC task scheduling and storage capacity.
