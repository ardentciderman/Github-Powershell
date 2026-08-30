# Hyper-V PowerShell Toolkit

A small PowerShell toolkit for building, validating, auditing, and documenting Hyper-V virtual machines on standalone Windows Server Hyper-V hosts.

This toolkit was developed incrementally through hands-on Hyper-V lab work, with an emphasis on:

- evidence before change
- safe, read-only validation where possible
- explicit desired state
- post-build verification
- configuration drift detection
- storage hygiene
- operator-friendly output
- conservative failure handling

The current toolkit contains five scripts:

```text
Hyper-V/
├── README.md
├── Get-HyperVStorageAudit.ps1
├── Get-HyperVVM-Baseline.ps1
├── HyperVHostReadiness.ps1
├── New-HyperVLabVM.ps1
└── Test-HyperVVMConfiguration.ps1
```
## Toolkit Workflow

The scripts are designed to work together as an operational workflow:

```text
HyperVHostReadiness.ps1
        ↓
New-HyperVLabVM.ps1
        ↓
Desired-state .psd1
        ↓
Test-HyperVVMConfiguration.ps1
        ↓
Get-HyperVVM-Baseline.ps1
        ↓
Get-HyperVStorageAudit.ps1
```

Conceptually:

```text
Host readiness
     ↓
VM provisioning
     ↓
Desired-state definition
     ↓
Expected vs actual validation
     ↓
Observed-state evidence
     ↓
Storage integrity / hygiene audit
```
## Requirements

The scripts were developed and tested against:

- Windows Server 2025
- Hyper-V role installed
- Windows PowerShell 5.1
- standalone Hyper-V host
- local Hyper-V storage
- Generation 2 Windows virtual machines

Most scripts should be run from an elevated PowerShell session.

Example:

```powershell
Start-Process powershell.exe -Verb RunAs
```

The toolkit currently assumes standard Hyper-V PowerShell cmdlets are available.

## 1. HyperVHostReadiness.ps1
### Purpose

Performs a read-only readiness assessment before creating or modifying a Hyper-V VM.

It is designed to answer:

Is this host in a sufficiently healthy and predictable state to begin VM provisioning?

### Checks

The script currently checks areas including:

- administrative privileges
- host information
- uptime
- pending reboot indicators
- Hyper-V availability
- VMMS service
- CPU utilisation
- available memory
- existing VMs
- requested VM name availability
- VHDX destination
- VHDX path collision
- installation ISO
- target volume health and capacity
- physical disk health
- Hyper-V default storage paths
- existing VM disk attachments
- Hyper-V virtual switches
- physical NICs
- checkpoints
- recent System events
- recent Hyper-V VMMS events
- recent storage-related events

Networking can intentionally be deferred.

For example, the absence of a virtual switch can be reported as informational rather than automatically treated as a failure.

### Example
```powershell
.\HyperVHostReadiness.ps1 `
    -VMName "LAB-APP01" `
    -VHDXPath "D:\Hyper-V\Virtual Hard Disks\LAB-APP01.vhdx" `
    -ISOPath "D:\Hyper-V\ISOs\WinServer2025.ISO"
```
### Result model
```text
PASS
INFO
WARNING
FAIL
```

Typical overall results:

```text
PASS
REVIEW
FAIL
```

Exit-code model:

- 0 = ready
- 1 = review required
- 2 = blocking failure
### Validation performed

The script was tested against a live standalone Hyper-V host before VM provisioning.

It correctly identified:

- valid Hyper-V state
- healthy storage
- available VM names
- valid ISO media
- sufficient disk capacity
- historical warnings requiring operator review
- intentionally absent virtual networking without treating it as a hard failure
## 2. New-HyperVLabVM.ps1
### Purpose

Creates a standard Generation 2 Hyper-V lab VM from explicit build parameters and validates each stage of the build.

The script was deliberately developed incrementally rather than as one large provisioning block.

The current version implements five stages.

### Stage 1 — Pre-Build Validation

Checks:

- administrative privileges
- Hyper-V availability
- VMMS
- VM name collision
- VHDX directory
- VHDX filename collision
- ISO availability
- target storage volume
- desired-state config collision

A blocking failure prevents VM creation.

### Stage 2 — VM Shell

Creates and validates:

- Generation 2 VM
- requested startup memory
- requested processor count
- Dynamic Memory disabled

Example expected configuration:

```text
Generation           : 2
ProcessorCount       : 2
MemoryStartupGB      : 4
DynamicMemoryEnabled : False
```
### Stage 3 — Virtual Disk

Creates:

- dynamically expanding VHDX
- requested maximum capacity
- OS disk at SCSI controller 0:0

The script validates:

- VHDX format
- VHD type
- virtual size
- attachment path
- SCSI controller
- SCSI location
### Stage 4 — Installation Media and Firmware

Configures:

- Windows installation ISO
- DVD drive at SCSI 0:1
- Secure Boot
- MicrosoftWindows Secure Boot template
- DVD as first firmware boot device

The VM remains powered off after provisioning.

The script does not automatically install Windows.

### Stage 5 — Desired State and Drift Validation

Creates:

```text
C:\HyperV-Baselines\Config\<VMName>.psd1
```

The .psd1 is generated from the requested build specification, not from the resulting live VM.

This is an important design rule:

```text
Requested configuration = desired state
Live Hyper-V VM         = actual state
```

The generated desired-state file is then passed to:

Test-HyperVVMConfiguration.ps1

and the build is only considered complete when the validator passes.

### Example
```powershell
.\New-HyperVLabVM.ps1 `
    -VMName "LAB-APP01" `
    -ProcessorCount 2 `
    -StartupMemoryGB 4 `
    -VHDSizeGB 60 `
    -VHDXPath "D:\Hyper-V\Virtual Hard Disks\LAB-APP01.vhdx" `
    -ISOPath "D:\Hyper-V\ISOs\WinServer2025.ISO"
```

Example final result:

```text
RESULT: PASS - HYPER-V LAB VM BUILD COMPLETE
```

Example resulting VM:

```text
LAB-APP01
├── Generation 2
├── 2 vCPU
├── 4 GB static startup memory
├── Dynamic Memory disabled
├── 60 GB dynamic VHDX
│   └── SCSI 0:0
├── Windows Server ISO
│   └── SCSI 0:1
├── Secure Boot enabled
├── MicrosoftWindows template
├── DVD first in boot order
├── no virtual switch
├── no checkpoints
└── Off / boot-ready
```
### Failure handling

The script intentionally does not automatically delete partially created resources.

If a later stage fails, it reports the partial state and expects the operator to inspect the environment before cleanup.

This avoids hiding useful evidence or accidentally removing the wrong VM or virtual disk.

## 3. Test-HyperVVMConfiguration.ps1
### Purpose

Compares the live Hyper-V configuration of a VM against a machine-readable desired-state .psd1.

This provides configuration drift detection.

### Example desired-state file
```powershell
@{
    VMName                  = "LAB-APP01"
    Generation              = 2
    ProcessorCount          = 2
    StartupMemoryGB         = 4
    DynamicMemoryEnabled    = $false

    VHDXPath                = "D:\Hyper-V\Virtual Hard Disks\LAB-APP01.vhdx"
    VHDSizeGB               = 60
    VHDType                 = "Dynamic"

    SecureBootEnabled       = $true
    SecureBootTemplate      = "MicrosoftWindows"

    ExpectedSwitchName      = ""
    ExpectedCheckpointCount = 0
```
}
### Example
```powershell
.\Test-HyperVVMConfiguration.ps1 `
    -ConfigFile "C:\HyperV-Baselines\Config\LAB-APP01.psd1"
```
### Current checks

The validator compares:

- Generation
- processor count
- startup memory
- Dynamic Memory state
- VHDX path
- VHDX maximum size
- VHD type
- Secure Boot
- Secure Boot template
- virtual switch connection
- checkpoint count
### Expected result

Healthy VM:

```text
PASS : 11
FAIL : 0

RESULT: PASS - VM MATCHES EXPECTED CONFIGURATION
```

Drift example:

```text
ProcessorCount    Expected 2    Actual 4    FAIL
```

Overall result:

```text
PASS : 10
FAIL : 1

RESULT: FAIL - CONFIGURATION DRIFT DETECTED
```
### Validation performed

The validator was tested using a deliberate CPU drift scenario.

Desired state:

```text
ProcessorCount = 2
```

The live VM was deliberately changed to:

```text
ProcessorCount = 4
```

The validator detected exactly one failed setting.

After restoring the VM to two processors, the validator returned:

```text
PASS : 11
FAIL : 0
```

This demonstrated that the desired-state file remained independent of the live VM.

## 4. Get-HyperVVM-Baseline.ps1
### Purpose

Captures a human-readable snapshot of the observed live configuration of a Hyper-V VM.

This is deliberately different from the desired-state .psd1.

The two concepts are:

```text
.psd1 desired state
    = what the VM should be

baseline transcript
    = what the VM was observed to be at a specific time
```

This makes the baseline useful for:

- troubleshooting
- audit evidence
- training records
- change comparison
- operational handoff
### Example
```powershell
.\Get-HyperVVM-Baseline.ps1 `
    -VMName "LAB-APP01"
```

The script writes a timestamped file beneath the configured baseline location.

Example:

```text
C:\HyperV-Baselines\LAB-APP01-20260830-010000.txt
```
### Captured information

The current script includes:

- VM configuration
- processor count
- memory
- VM state
- disk attachments
- VHD properties
- network adapters
- firmware
- Secure Boot
- DVD drives
- checkpoints
### Design intent

This script is read-only with respect to the VM.

The baseline should never be used to silently redefine desired state.

## 5. Get-HyperVStorageAudit.ps1
### Purpose

Performs a read-only storage health, integrity, and hygiene audit across Hyper-V VMs and virtual disk files.

It is intended to answer questions such as:

- Which virtual disks are attached?
- Do referenced disks actually exist?
- Are there orphaned VHDX files?
- Are there AVHDX files?
- Are there checkpoints?
- Are differencing-disk chains intact?
- Are VMs sharing the same virtual disk unexpectedly?
- Are installation ISOs still attached?
- Is the underlying storage volume healthy?
### Example — host-wide audit
```powershell
.\Get-HyperVStorageAudit.ps1 `
    -OutputDirectory "C:\HyperV-Baselines\StorageAudit"
```
### Example — single VM
```powershell
.\Get-HyperVStorageAudit.ps1 `
    -VMName "LAB-APP01"
```
### Example — strict attached ISO policy
```powershell
.\Get-HyperVStorageAudit.ps1 `
    -WarnOnAttachedISO
```

In normal mode, a valid attached ISO is informational.

With:

```powershell
-WarnOnAttachedISO
```

an attached ISO becomes a review condition.

### Storage audit areas

The script currently checks:

- VM storage attachments
- VHD/VHDX references
- missing referenced files
- controller type
- controller number
- controller location
- VHD/VHDX metadata
- disk format
- disk type
- virtual size
- physical size
- parent path
- differencing chains
- Checkpoints
- checkpoint count
- checkpoint inventory
- AVHD/AVHDX files
#### Orphan detection

Files beneath the audited VHD path that are not part of a known registered VM chain are reported as:

```text
WARNING
```

They are deliberately called:

```text
Potentially orphaned
```

rather than automatically classified as safe to delete.

A file may legitimately belong to:

- an unregistered VM
- a backup
- a template
- a manually retained disk
- an imported VM
- another workflow

The script never deletes storage.

#### ISO inventory

Reports:

- attached ISO files
- missing ISO references
- optional warnings for mounted installation media
#### Storage volume

Reports:

- filesystem
- health
- total capacity
- free capacity
- free percentage
#### Friendly Physical Size Reporting

Small dynamic disks are displayed using an adaptive physical-size field.

Instead of:

```text
0 GB
```

a newly created VHDX can display as:

```text
4 MB
```

while larger disks display naturally:

```text
15.88 GB
16.63 GB
```
### Storage Audit Validation

The storage audit was tested through several scenarios.

#### Clean-state test

Expected:

```text
Potential Orphan Disks : 0
AVHD / AVHDX Files     : 0
Checkpoints            : 0
WARNING                : 0
FAIL                   : 0

RESULT: PASS - STORAGE AUDIT CLEAN
```
#### Strict ISO test

With:

```powershell
-WarnOnAttachedISO
```

valid mounted ISO media produced warnings and:

```text
RESULT: REVIEW - STORAGE FINDINGS REQUIRE REVIEW
```

with no hard storage failures.

#### Controlled orphan test

A disposable unattached disk was created:

```powershell
New-VHD `
    -Path "D:\Hyper-V\Virtual Hard Disks\TEST-ORPHAN.vhdx" `
    -SizeBytes 1GB `
    -Dynamic
```

The audit correctly reported:

```text
Potential Orphan Disks : 1
WARNING                 : 1
FAIL                    : 0

RESULT: REVIEW - STORAGE FINDINGS REQUIRE REVIEW
```

The disposable disk was then removed and the audit returned to:

```text
WARNING : 0
FAIL    : 0

RESULT: PASS - STORAGE AUDIT CLEAN
```

This validated both orphan detection and recovery to a clean state.

## Desired State vs Observed State

A core design principle of this toolkit is to keep these concepts separate.

### Desired state

```text
Stored as:
```

.psd1

Example:

```text
C:\HyperV-Baselines\Config\LAB-APP01.psd1
```

Defines what the VM should look like.

Used by:

```powershell
Test-HyperVVMConfiguration.ps1
```
### Observed state

Stored as a timestamped human-readable baseline.

Defines what the VM was actually observed to look like at a particular point in time.

Produced by:

```powershell
Get-HyperVVM-Baseline.ps1
```

The observed state should not automatically overwrite desired state.

## Safety Philosophy

These scripts favour conservative behaviour.

Examples:

- existing VM names are treated as collisions
- existing VHDX files are not overwritten
- existing desired-state files are not silently replaced
- missing disk references are surfaced rather than repaired automatically
- orphaned disks are never automatically deleted
- failed builds do not automatically destroy partial resources
- storage audits are read-only
- desired state is not generated by blindly copying the live configuration

The operator remains responsible for reviewing evidence before destructive action.

## Current Limitations

The current toolkit is intentionally scoped.

It does not currently provide:

- guest OS unattended installation
- Active Directory configuration
- DNS configuration
- Hyper-V virtual switch provisioning
- VLAN configuration
- Live Migration configuration
- Failover Clustering
- Cluster Shared Volumes
- Storage Spaces Direct
- automatic checkpoint cleanup
- automatic orphan cleanup
- automatic VHD repair
- production change approval workflows

Virtual networking is intentionally outside the current toolkit scope and is expected to be developed separately.

## Suggested Operational Sequence

Before building a VM:

```powershell
.\HyperVHostReadiness.ps1 ...
```

Build the VM:

```powershell
.\New-HyperVLabVM.ps1 ...
```

Validate later for drift:

```powershell
.\Test-HyperVVMConfiguration.ps1 `
    -ConfigFile "C:\HyperV-Baselines\Config\<VM>.psd1"
```

Capture human-readable evidence:

```powershell
.\Get-HyperVVM-Baseline.ps1 `
    -VMName "<VM>"
```

Audit storage:

```powershell
.\Get-HyperVStorageAudit.ps1 `
    -OutputDirectory "C:\HyperV-Baselines\StorageAudit"
```
## Example End-to-End Flow
```text
1. Host readiness
       ↓
2. Build LAB-APP01
       ↓
3. Create LAB-APP01.psd1
       ↓
4. Validate expected vs actual
       ↓
5. Capture observed baseline
       ↓
6. Audit storage
       ↓
7. Deliberately introduce drift
       ↓
8. Validator detects drift
       ↓
9. Restore configuration
       ↓
10. Validator returns PASS
```
## Development Status

The current five-script toolkit has been exercised through:

- successful host-readiness validation
- complete Generation 2 VM provisioning
- VHDX creation and attachment
- ISO attachment
- Secure Boot configuration
- firmware boot-order validation
- desired-state generation
- expected-vs-actual validation
- deliberate CPU configuration drift
- drift remediation
- baseline capture
- clean storage audit
- strict attached-ISO warning mode
- deliberate orphaned VHDX detection
- orphan cleanup
- return-to-clean storage verification

The current scripts are suitable as a personal Hyper-V engineering and operational-support toolkit for continued lab development.

## Repository Guidance

Do not commit sensitive or environment-specific evidence unless intentionally sanitised.

Examples to review before committing:

- actual baseline transcripts
- hostnames
- MAC addresses
- IP addresses
- internal paths
- production VM names
- event logs
- environment-specific configuration
- credentials or secrets

Example .psd1 files can be committed using generic lab values.

## Future Work

Possible future additions include:

- Hyper-V virtual networking tooling
- virtual-switch health checks
- VM network drift validation
- VLAN validation
- automated VM build transcripts
- Pester tests
- JSON/CSV audit export
- reusable configuration schemas
- logging helpers shared between scripts
- PowerShell module packaging
- signed script releases
- GitHub Actions linting / validation
## Disclaimer

These scripts are intended for lab, learning, engineering, and controlled operational use.

Always review commands and understand their effect before using them in production environments.
