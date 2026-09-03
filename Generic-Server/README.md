# Generic Servers

This folder contains reusable PowerShell tooling for **general Windows Server health checking**.

The current primary script is:

`WSAudit-Core.ps1`

---

## WSAudit Core

**WSAudit Core** is the generic Windows Server health-check component of the wider **WSAudit** project.

WSAudit stands for:

**Windows Server Operations, Security & Resilience Auditor**

At the current stage, WSAudit Core is intended for:

- Morning health checks
- General Windows Server validation
- Action1 execution
- Read-only operational checks

---

## Current State

WSAudit Core is currently at **v0.1.0 / Checkpoint 15**.

At this stage it is:

- Suitable for general Windows Server morning health checks
- Read-only
- Tested with local PowerShell execution
- Tested through Action1
- Using structured PASS / WARN / FAIL / INFO results
- Producing Action1-friendly text output
- Ready to be used as the common Windows health layer across general servers

It does not yet include:

- Morning / PrePatch / PostPatch operating modes
- Baseline save and comparison logic
- Final Action1 exit-code handling
- Role-specific checks for Active Directory, File Server, Arcserve, SQL, IIS, or other workloads

The current script should therefore be treated as the **stable generic Windows Server health core** while the wider WSAudit framework continues to be developed.

---

## Current Checks

WSAudit Core currently checks:

- Operating system version and build
- Kernel uptime
- Local disk free space
- Pending reboot state
- Core Windows services
- Physical disk health
- Memory utilisation
- CPU utilisation
- Generic System event errors
- Service Control Manager failure events
- Storage-related events
- Unexpected shutdown / crash events
- WHEA hardware error events

---

## Check IDs

WSAudit uses stable machine-readable check IDs.

Current examples include:

```text
WIN.SYSTEM.OS
WIN.OPERATING.KERNEL_UPTIME
WIN.STORAGE.DISKSPACE
WIN.OPERATING.REBOOT_PENDING
WIN.SERVICE.EVENTLOG
WIN.SERVICE.WINMGMT
WIN.SERVICE.LANMANSERVER
WIN.SERVICE.SCHEDULE
WIN.SERVICE.RPCSS
WIN.STORAGE.PHYSICALDISK
WIN.PERFORMANCE.MEMORY
WIN.PERFORMANCE.CPU
WIN.EVENT.SYSTEM.SUMMARY
WIN.EVENT.SYSTEM.SAMPLE
WIN.EVENT.SERVICE_FAILURE
WIN.EVENT.SERVICE_FAILURE.SAMPLE
WIN.EVENT.STORAGE
WIN.EVENT.STORAGE.SAMPLE
WIN.EVENT.UNEXPECTED_SHUTDOWN
WIN.EVENT.UNEXPECTED_SHUTDOWN.SAMPLE
WIN.EVENT.WHEA
WIN.EVENT.WHEA.SAMPLE
```

These IDs are intended to remain stable so that future reporting, baseline comparison and automation can rely on them.

---

## Status Values

WSAudit uses the following statuses:

- **PASS** — Expected condition met
- **WARN** — Review recommended
- **FAIL** — Unhealthy condition detected
- **INFO** — Informational result only

---

## Current Thresholds

### Disk Space

```text
PASS    >= 15% free
WARN    < 15% free
FAIL    < 8% free
```

### Memory Utilisation

```text
PASS    < 85% used
WARN    >= 85% used
FAIL    >= 95% used
```

### CPU Utilisation

CPU is sampled multiple times rather than relying on a single reading.

Current default:

```text
5 samples
1 second between samples
```

Average utilisation is classified as:

```text
PASS    < 85%
WARN    >= 85%
FAIL    >= 95%
```

Peak CPU is also reported for context.

---

## Core Windows Services

WSAudit Core currently checks:

- Windows Event Log
- Windows Management Instrumentation
- Server
- Task Scheduler
- Remote Procedure Call (RPC)

Current logic:

```text
PASS    Service is running
FAIL    Service exists but is not running
WARN    Service cannot be queried
```

---

## Event Log Philosophy

WSAudit deliberately separates broad event-log awareness from targeted health checks.

A Windows event being marked **Error** or **Critical** does not automatically mean that the server itself is unhealthy.

Classification can depend on:

- Provider
- Event ID
- Frequency
- Timing
- Server role
- Related events
- Current service state
- Hardware state
- Workload context

The generic System event check therefore provides visibility without treating every Error or Critical event as an automatic server failure.

More specific checks apply stronger context where appropriate.

---

## Generic System Events

The generic System event summary examines recent Critical and Error events in the Windows System log.

Default lookback:

```text
24 hours
```

Current logic:

```text
PASS    No Critical/Error events detected
WARN    One or more Critical/Error events detected
```

Representative samples are also produced from the most common:

```text
Provider + Event ID
```

groups.

This helps prevent repeated copies of the same event from hiding less frequent but potentially important events.

---

## Service Failure Events

WSAudit checks Service Control Manager events associated with:

- Service startup failures
- Dependency failures
- Service timeouts
- Hung services
- Unexpected service termination

Current logic:

```text
PASS    No monitored service failure events
WARN    One or more monitored events detected
```

Historical service events do not automatically produce a FAIL result.

The current state of core Windows services is checked separately.

---

## Storage Events

WSAudit checks Critical and Error events from storage-related Windows providers, including:

- Disk
- NTFS
- Storage controllers
- Storport
- Storage ClassPnP
- Storage Spaces
- Volume management
- Volume Shadow Copy

Current logic:

```text
PASS    No targeted storage Critical/Error events
WARN    One or more targeted storage events detected
```

`VDS Basic Provider` and `Virtual Disk Service` events remain visible through the generic System event summary but are not currently classified as direct storage failure.

This is intentional.

---

## Unexpected Shutdown / Crash Detection

WSAudit checks for events associated with:

- Unexpected shutdown
- Power loss
- Kernel-Power
- Bugchecks
- System crashes

Current logic:

```text
PASS    No monitored shutdown/crash events
WARN    One or more historical events detected
```

Future PostPatch mode will be able to distinguish historical events from new events that occur during a patch cycle.

---

## WHEA Hardware Error Detection

WSAudit checks Windows Hardware Error Architecture events from:

```text
Microsoft-Windows-WHEA-Logger
```

WHEA is handled separately because corrected hardware errors may be recorded at Warning level.

Current logic:

```text
PASS    No WHEA events detected

WARN    WHEA events detected but none are Critical/Error

FAIL    One or more Critical/Error WHEA events detected
```

WHEA events should be reviewed in context before assuming a particular CPU, memory module, PCIe device or other physical component has failed.

---

## Physical Disk Health

WSAudit uses:

```powershell
Get-PhysicalDisk
```

to inspect storage health information exposed by Windows.

Current logic:

```text
PASS    Healthy / OK
WARN    Non-standard or indeterminate state
FAIL    Unhealthy, Error, No Contact, Lost Communication,
        Predictive Failure, or similar failure state
```

> RAID, SAN and virtualisation platforms may abstract the underlying hardware. WSAudit reports the health information that Windows can see.

---

## Pending Reboot

WSAudit checks common reboot indicators including:

- Component Based Servicing
- Windows Update
- Pending file rename operations

Current logic:

```text
PASS    No reboot indicators detected
WARN    One or more reboot indicators detected
```

Pending reboot handling may be refined further as Morning and Patch modes are developed.

---

## Result Model

Every WSAudit check returns the same structured result format.

Example:

```powershell
[PSCustomObject]@{
    Id        = 'WIN.STORAGE.DISKSPACE'
    Category  = 'Storage'
    Check     = 'Disk Space'
    Resource  = 'C:'
    Status    = 'PASS'
    Value     = 42
    Expected  = '>= 15%'
    Details   = '168 GB free of 400 GB'
    Timestamp = Get-Date
    Data      = $null
}
```

This common result model is intended to support future:

- JSON output
- Baseline files
- Pre/post patch comparison
- HTML reporting
- Historical reporting
- Action1 integration

---

## Action1

WSAudit Core has been designed and tested with **Action1 endpoint execution**.

Output is deliberately written as explicit text blocks rather than using:

```powershell
Format-Table
```

This avoids remote-console issues such as:

- Flattened tables
- Truncated columns
- Missing detail

Visible separator lines are also used between results to improve readability in Action1 output.

---

## Planned Exit Codes

The intended Action1 exit-code convention is:

```text
0    PASS or WARN
1    FAIL
2    Script/runtime error
```

Exit-code handling is **not yet implemented in v0.1.0 / Checkpoint 15**.

For now, the script output should be reviewed directly.

---

## Safety

WSAudit Core is currently **read-only**.

It does not:

- Restart services
- Reboot servers
- Change registry settings
- Modify Windows configuration
- Clear event logs
- Delete event history
- Repair disks
- Modify storage
- Install software

The script only collects and evaluates health information.

---

## Running the Script

Run locally from PowerShell:

```powershell
.\WSAudit-Core.ps1
```

The script can also be executed through **Action1**.

Administrator-level execution is recommended so that Windows health and event information can be queried consistently.

---

## Current Scope

Checkpoint 15 should be considered:

> **Generic Windows Server Morning Health Core**

It is suitable as a common health-check baseline across general Windows Server systems.

It does **not yet replace workload-specific health checks**.

For example:

```text
Domain Controller
    WSAudit Core
    + Active Directory
    + DNS
    + Replication

File Server
    WSAudit Core
    + SMB
    + Shares
    + File-server-specific storage checks

Arcserve Server
    WSAudit Core
    + Arcserve services
    + Backup jobs
    + Backup-specific events
    + Repository / datastore validation
```

Other future role profiles may include:

- SQL Server
- IIS
- Application servers
- Other workload-specific systems

---

## Planned Development

The next phase of WSAudit development will introduce:

- Baseline persistence
- Morning mode
- PrePatch mode
- PostPatch mode
- Pre/post comparison logic
- Action1 exit-code handling
- Role-specific server profiles

The intended operational model is eventually:

```powershell
.\WSAudit.ps1 -Mode Morning

.\WSAudit.ps1 -Mode PrePatch

.\WSAudit.ps1 -Mode PostPatch
```

---

## Future Project Direction

The intended long-term WSAudit architecture is:

```text
WSAudit
│
├── Core
│   ├── Results
│   ├── Status calculation
│   ├── Console output
│   ├── JSON
│   ├── Baselines
│   ├── Report retention
│   └── Action1 exit codes
│
├── Checks
│   ├── Windows
│   ├── ActiveDirectory
│   ├── Arcserve
│   ├── FileServer
│   ├── Security
│   └── Storage
│
└── Modes
    ├── Morning
    ├── PrePatch
    └── PostPatch
```

The goal is to retain **one main WSAudit entry point** for local and Action1 execution, even if the internal project is later separated into modules for maintainability.

---

## Version History

### v0.1.0 — Checkpoint 15

Initial reusable Windows Server health core.

Validated functionality includes:

- Operating system information
- Kernel uptime
- Disk-space thresholds
- Pending reboot detection
- Critical Windows services
- Physical disk health
- Memory utilisation
- CPU sampling
- Generic System event summary
- Representative event sampling
- Targeted service failure events
- Targeted storage events
- Unexpected shutdown / crash detection
- WHEA hardware error detection
- Action1-readable console output

---

## Development Status

WSAudit is under active development.

`WSAudit-Core.ps1` is the current known-good generic Windows Server health-check baseline and can be used for production morning health checking while the wider WSAudit framework continues to be developed.
