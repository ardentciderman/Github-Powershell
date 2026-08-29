<#
.SYNOPSIS
    Standalone Hyper-V Host and VM Pre-Build Readiness Check

.DESCRIPTION
    Performs read-only checks against a standalone Hyper-V host using
    local storage before creating a new virtual machine.

    The following values are supplied as parameters:

        - VM Name
        - VHDX Path
        - ISO Path

    All other thresholds and behaviour remain static within the script.

    IMPORTANT BUILD ASSUMPTION
    --------------------------
    Networking is intentionally deferred for this build process.

    Therefore:

        No Hyper-V virtual switch = INFO / expected condition

    It does NOT prevent the VM from being created.

    The VM should be created without connecting it to a Hyper-V virtual
    switch. Networking can be configured later.

    RESULT LOGIC
    ------------
    PASS:
        No blocking failures and no review warnings.

    REVIEW:
        No blocking failures, but one or more warnings require review.

    FAIL:
        One or more conditions exist that should prevent the VM build.

    Exit codes:
        0 = PASS
        1 = REVIEW
        2 = FAIL

.NOTES
    Intended for:
        - Standalone Hyper-V
        - Local VM storage
        - Networking intentionally deferred
        - Windows Server Hyper-V

    This script does NOT make any configuration changes.

.EXAMPLE
    .\Test-HyperVHostReadiness.ps1 `
        -VMName "LAB-DC01" `
        -VHDXPath "D:\Hyper-V\Virtual Hard Disks\LAB-DC01.vhdx" `
        -ISOPath "D:\Hyper-V\ISOs\WinServer2025.ISO"
#>


# ============================================================================
# PARAMETERS
# ============================================================================

[CmdletBinding()]
param (

    # Name that will be assigned to the new Hyper-V VM.
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$VMName,

    # Full path of the VHDX that will be created for the new VM.
    #
    # Example:
    # D:\Hyper-V\Virtual Hard Disks\LAB-DC01.vhdx
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$VHDXPath,

    # Full path to the Windows installation ISO.
    #
    # Example:
    # D:\Hyper-V\ISOs\WinServer2025.ISO
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ISOPath
)


# ============================================================================
# STATIC CONFIGURATION
# ============================================================================

# Networking is deliberately deferred for this build process.
#
# Consequently, the absence of a Hyper-V virtual switch is NOT considered
# a warning or failure.
$NetworkingDeferred = $true


# Warn if sampled host CPU utilisation is at or above this percentage.
$CpuWarningThresholdPercent = 75


# Warn if currently available physical RAM is below this value.
$MinimumFreeMemoryGB = 8


# Warn if a local volume has less than this percentage of capacity free.
$MinimumFreeDiskPercent = 20


# Warn if a local volume has less than this absolute amount of capacity free.
$MinimumFreeDiskGB = 50


# Number of days of Windows Event Logs to inspect.
$EventLogLookbackDays = 7


# Maximum number of events displayed for each Event Log check.
$MaximumEventsToDisplay = 20


# ============================================================================
# INITIALISE RESULT COLLECTION
# ============================================================================

# Every check writes a result into this collection.
#
# Status meanings:
#
# PASS
#     The check completed successfully and the condition is acceptable.
#
# WARNING
#     The condition needs human review but does not automatically prevent
#     the build.
#
# FAIL
#     The condition should prevent the VM build.
#
# INFO
#     Informational or expected condition requiring no action.

$Results = @()


# ============================================================================
# HELPER FUNCTION - ADD CHECK RESULT
# ============================================================================

function Add-CheckResult {

    param (

        [Parameter(Mandatory)]
        [string]$Check,

        [Parameter(Mandatory)]
        [ValidateSet(
            'PASS',
            'WARNING',
            'FAIL',
            'INFO'
        )]
        [string]$Status,

        [Parameter(Mandatory)]
        [string]$Details
    )

    $script:Results += [PSCustomObject]@{
        Check   = $Check
        Status  = $Status
        Details = $Details
    }
}


# ============================================================================
# HELPER FUNCTION - SECTION HEADER
# ============================================================================

function Write-Section {

    param (

        [Parameter(Mandatory)]
        [string]$Title
    )

    Write-Host ""
    Write-Host "============================================================================"
    Write-Host $Title
    Write-Host "============================================================================"
}


# ============================================================================
# HELPER FUNCTION - OUTPUT STATUS
# ============================================================================

function Write-Status {

    param (

        [Parameter(Mandatory)]
        [ValidateSet(
            'PASS',
            'WARNING',
            'FAIL',
            'INFO'
        )]
        [string]$Status,

        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Host ("{0}: {1}" -f $Status, $Message)
}


# ============================================================================
# SCRIPT HEADER
# ============================================================================

Clear-Host

Write-Host ""
Write-Host "Hyper-V Standalone Host Pre-Build Readiness Check"
Write-Host ""
Write-Host "Host      : $env:COMPUTERNAME"
Write-Host "VM Name   : $VMName"
Write-Host "VHDX Path : $VHDXPath"
Write-Host "ISO Path  : $ISOPath"
Write-Host "Date      : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ""
Write-Host "Networking: Deferred"
Write-Host ""


# ============================================================================
# 1. ADMINISTRATIVE PRIVILEGES
# ============================================================================

Write-Section "1. Administrative Privileges"

# Hyper-V, storage and Event Log checks can require administrative rights.
#
# If the script is not elevated, later results could be incomplete or
# misleading, so this is treated as a blocking failure.

$CurrentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()

$Principal = New-Object `
    Security.Principal.WindowsPrincipal($CurrentIdentity)

$IsAdministrator = $Principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)


if ($IsAdministrator) {

    Write-Status `
        -Status "PASS" `
        -Message "PowerShell is running elevated."

    Add-CheckResult `
        -Check "Administrative privileges" `
        -Status "PASS" `
        -Details "PowerShell is running as Administrator."
}
else {

    Write-Status `
        -Status "FAIL" `
        -Message "PowerShell is not running elevated."

    Add-CheckResult `
        -Check "Administrative privileges" `
        -Status "FAIL" `
        -Details "Run PowerShell as Administrator."

    # There is little value continuing because subsequent Hyper-V and
    # storage checks may fail purely because of permissions.
    return
}


# ============================================================================
# 2. HOST INFORMATION
# ============================================================================

Write-Section "2. Host Information"

try {

    $OS = Get-CimInstance `
        -ClassName Win32_OperatingSystem `
        -ErrorAction Stop

    $ComputerSystem = Get-CimInstance `
        -ClassName Win32_ComputerSystem `
        -ErrorAction Stop

    Write-Host "Computer Name : $env:COMPUTERNAME"
    Write-Host "OS            : $($OS.Caption)"
    Write-Host "Version       : $($OS.Version)"
    Write-Host "Build         : $($OS.BuildNumber)"
    Write-Host "Manufacturer  : $($ComputerSystem.Manufacturer)"
    Write-Host "Model         : $($ComputerSystem.Model)"

    Add-CheckResult `
        -Check "Host information" `
        -Status "INFO" `
        -Details "$($OS.Caption), build $($OS.BuildNumber)."
}
catch {

    Write-Status `
        -Status "WARNING" `
        -Message "Unable to retrieve complete host information."

    Add-CheckResult `
        -Check "Host information" `
        -Status "WARNING" `
        -Details $_.Exception.Message
}


# ============================================================================
# 3. HOST UPTIME
# ============================================================================

Write-Section "3. Host Uptime"

try {

    $OS = Get-CimInstance `
        -ClassName Win32_OperatingSystem `
        -ErrorAction Stop

    $Uptime = (Get-Date) - $OS.LastBootUpTime

    $UptimeText = (
        "{0} days, {1} hours, {2} minutes" -f `
        $Uptime.Days,
        $Uptime.Hours,
        $Uptime.Minutes
    )

    Write-Host "Host uptime: $UptimeText"

    Add-CheckResult `
        -Check "Host uptime" `
        -Status "INFO" `
        -Details $UptimeText
}
catch {

    Add-CheckResult `
        -Check "Host uptime" `
        -Status "WARNING" `
        -Details "Unable to determine host uptime."
}


# ============================================================================
# 4. PENDING REBOOT
# ============================================================================

Write-Section "4. Pending Reboot"

# A pending reboot is not automatically considered a failed host.
#
# It is, however, something that should be reviewed before adding another
# workload because maintenance may already be outstanding.

$PendingReboot = $false
$PendingRebootReasons = @()


# Check Component Based Servicing.
if (
    Test-Path `
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
) {

    $PendingReboot = $true
    $PendingRebootReasons += "Component Based Servicing"
}


# Check Windows Update.
if (
    Test-Path `
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
) {

    $PendingReboot = $true
    $PendingRebootReasons += "Windows Update"
}


# Check pending file rename operations.
$PendingFileRename = (
    Get-ItemProperty `
        -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
        -Name PendingFileRenameOperations `
        -ErrorAction SilentlyContinue
).PendingFileRenameOperations


if ($PendingFileRename) {

    $PendingReboot = $true
    $PendingRebootReasons += "Pending file rename operation"
}


if ($PendingReboot) {

    $ReasonText = $PendingRebootReasons -join ", "

    Write-Status `
        -Status "WARNING" `
        -Message "A reboot appears to be pending: $ReasonText"

    Add-CheckResult `
        -Check "Pending reboot" `
        -Status "WARNING" `
        -Details "Pending reboot detected: $ReasonText."
}
else {

    Write-Status `
        -Status "PASS" `
        -Message "No common pending reboot indicators detected."

    Add-CheckResult `
        -Check "Pending reboot" `
        -Status "PASS" `
        -Details "No common pending reboot indicators detected."
}


# ============================================================================
# 5. HYPER-V AVAILABILITY
# ============================================================================

Write-Section "5. Hyper-V Availability"

# Get-VMHost provides a useful functional test:
#
#   1. Hyper-V PowerShell commands exist.
#   2. The local Hyper-V host can actually be queried.
#
# Failure here is considered build-blocking.

if (
    Get-Command `
        -Name Get-VMHost `
        -ErrorAction SilentlyContinue
) {

    try {

        $VMHost = Get-VMHost `
            -ErrorAction Stop

        Write-Status `
            -Status "PASS" `
            -Message "Hyper-V host is available."

        Write-Host ""
        Write-Host "Default VM Path   : $($VMHost.VirtualMachinePath)"
        Write-Host "Default VHDX Path : $($VMHost.VirtualHardDiskPath)"

        Add-CheckResult `
            -Check "Hyper-V availability" `
            -Status "PASS" `
            -Details "Hyper-V host successfully queried."
    }
    catch {

        Write-Status `
            -Status "FAIL" `
            -Message "Hyper-V host could not be queried."

        Add-CheckResult `
            -Check "Hyper-V availability" `
            -Status "FAIL" `
            -Details $_.Exception.Message
    }
}
else {

    Write-Status `
        -Status "FAIL" `
        -Message "Hyper-V PowerShell commands are unavailable."

    Add-CheckResult `
        -Check "Hyper-V availability" `
        -Status "FAIL" `
        -Details "Get-VMHost command was not found."
}


# ============================================================================
# 6. HYPER-V VMMS SERVICE
# ============================================================================

Write-Section "6. Hyper-V Virtual Machine Management Service"

# VMMS is required to manage Hyper-V virtual machines.
#
# If it is not running, the VM build should not proceed.

try {

    $VMMS = Get-Service `
        -Name vmms `
        -ErrorAction Stop

    Write-Host "VMMS Status: $($VMMS.Status)"

    if ($VMMS.Status -eq 'Running') {

        Write-Status `
            -Status "PASS" `
            -Message "VMMS service is running."

        Add-CheckResult `
            -Check "Hyper-V VMMS service" `
            -Status "PASS" `
            -Details "VMMS service is running."
    }
    else {

        Write-Status `
            -Status "FAIL" `
            -Message "VMMS service is $($VMMS.Status)."

        Add-CheckResult `
            -Check "Hyper-V VMMS service" `
            -Status "FAIL" `
            -Details "VMMS service state is $($VMMS.Status)."
    }
}
catch {

    Write-Status `
        -Status "FAIL" `
        -Message "Unable to query the VMMS service."

    Add-CheckResult `
        -Check "Hyper-V VMMS service" `
        -Status "FAIL" `
        -Details $_.Exception.Message
}


# ============================================================================
# 7. CPU CONFIGURATION
# ============================================================================

Write-Section "7. CPU Configuration"

try {

    $Processors = @(
        Get-CimInstance `
            -ClassName Win32_Processor `
            -ErrorAction Stop
    )

    $TotalCores = (
        $Processors |
        Measure-Object `
            -Property NumberOfCores `
            -Sum
    ).Sum

    $TotalLogicalProcessors = (
        $Processors |
        Measure-Object `
            -Property NumberOfLogicalProcessors `
            -Sum
    ).Sum

    Write-Host "CPU Sockets        : $($Processors.Count)"
    Write-Host "Physical Cores     : $TotalCores"
    Write-Host "Logical Processors : $TotalLogicalProcessors"

    foreach ($Processor in $Processors) {

        Write-Host "CPU                : $($Processor.Name)"
    }

    Add-CheckResult `
        -Check "CPU configuration" `
        -Status "INFO" `
        -Details "$TotalCores physical cores / $TotalLogicalProcessors logical processors."
}
catch {

    Add-CheckResult `
        -Check "CPU configuration" `
        -Status "WARNING" `
        -Details "Unable to retrieve CPU information."
}


# ============================================================================
# 8. CURRENT CPU UTILISATION
# ============================================================================

Write-Section "8. Current CPU Utilisation"

# Five samples are taken one second apart.
#
# This is only a short-term indication of host load. It should not be treated
# as a substitute for historical performance monitoring.

try {

    $CpuSamples = Get-Counter `
        '\Processor(_Total)\% Processor Time' `
        -SampleInterval 1 `
        -MaxSamples 5 `
        -ErrorAction Stop

    $AverageCPU = (
        $CpuSamples.CounterSamples.CookedValue |
        Measure-Object -Average
    ).Average

    $AverageCPU = [math]::Round(
        $AverageCPU,
        1
    )

    Write-Host "Average sampled CPU utilisation: $AverageCPU%"

    if ($AverageCPU -ge $CpuWarningThresholdPercent) {

        Write-Status `
            -Status "WARNING" `
            -Message "CPU utilisation is above the review threshold."

        Add-CheckResult `
            -Check "CPU utilisation" `
            -Status "WARNING" `
            -Details "$AverageCPU% average; review threshold is $CpuWarningThresholdPercent%."
    }
    else {

        Write-Status `
            -Status "PASS" `
            -Message "CPU utilisation is below the review threshold."

        Add-CheckResult `
            -Check "CPU utilisation" `
            -Status "PASS" `
            -Details "$AverageCPU% average."
    }
}
catch {

    Write-Status `
        -Status "WARNING" `
        -Message "CPU utilisation could not be measured."

    Add-CheckResult `
        -Check "CPU utilisation" `
        -Status "WARNING" `
        -Details "Unable to retrieve Processor performance counter data."
}


# ============================================================================
# 9. HOST MEMORY
# ============================================================================

Write-Section "9. Host Memory"

try {

    $OS = Get-CimInstance `
        -ClassName Win32_OperatingSystem `
        -ErrorAction Stop

    $TotalMemoryGB = [math]::Round(
        $OS.TotalVisibleMemorySize / 1MB,
        2
    )

    $FreeMemoryGB = [math]::Round(
        $OS.FreePhysicalMemory / 1MB,
        2
    )

    $UsedMemoryGB = [math]::Round(
        $TotalMemoryGB - $FreeMemoryGB,
        2
    )

    $MemoryUsedPercent = [math]::Round(
        ($UsedMemoryGB / $TotalMemoryGB) * 100,
        1
    )

    Write-Host "Total RAM     : $TotalMemoryGB GB"
    Write-Host "Used RAM      : $UsedMemoryGB GB"
    Write-Host "Available RAM : $FreeMemoryGB GB"
    Write-Host "Memory Used   : $MemoryUsedPercent%"

    if ($FreeMemoryGB -lt $MinimumFreeMemoryGB) {

        Write-Status `
            -Status "WARNING" `
            -Message "Available memory is below the configured review threshold."

        Add-CheckResult `
            -Check "Available physical memory" `
            -Status "WARNING" `
            -Details "$FreeMemoryGB GB available; threshold is $MinimumFreeMemoryGB GB."
    }
    else {

        Write-Status `
            -Status "PASS" `
            -Message "Current host memory headroom is acceptable."

        Add-CheckResult `
            -Check "Available physical memory" `
            -Status "PASS" `
            -Details "$FreeMemoryGB GB available."
    }
}
catch {

    Write-Status `
        -Status "FAIL" `
        -Message "Unable to determine host memory availability."

    Add-CheckResult `
        -Check "Available physical memory" `
        -Status "FAIL" `
        -Details $_.Exception.Message
}


# ============================================================================
# 10. EXISTING VIRTUAL MACHINES
# ============================================================================

Write-Section "10. Existing Virtual Machines"

try {

    $VMs = @(
        Get-VM `
            -ErrorAction Stop
    )

    if ($VMs.Count -eq 0) {

        Write-Status `
            -Status "INFO" `
            -Message "No existing VMs were found."

        Add-CheckResult `
            -Check "Existing virtual machines" `
            -Status "INFO" `
            -Details "No existing VMs found."
    }
    else {

        $VMs |
            Select-Object `
                Name,
                State,
                CPUUsage,
                ProcessorCount,
                @{
                    Name = 'MemoryAssignedGB'
                    Expression = {
                        [math]::Round(
                            $_.MemoryAssigned / 1GB,
                            2
                        )
                    }
                } |
            Format-Table -AutoSize

        $TotalVCPU = (
            $VMs |
            Measure-Object `
                -Property ProcessorCount `
                -Sum
        ).Sum

        $TotalAssignedMemoryGB = [math]::Round(
            (
                $VMs |
                Measure-Object `
                    -Property MemoryAssigned `
                    -Sum
            ).Sum / 1GB,
            2
        )

        Add-CheckResult `
            -Check "Existing virtual machines" `
            -Status "INFO" `
            -Details "$($VMs.Count) VM(s); $TotalVCPU configured vCPUs; $TotalAssignedMemoryGB GB assigned RAM."
    }
}
catch {

    Write-Status `
        -Status "WARNING" `
        -Message "Existing VMs could not be enumerated."

    Add-CheckResult `
        -Check "Existing virtual machines" `
        -Status "WARNING" `
        -Details $_.Exception.Message
}


# ============================================================================
# 11. PROPOSED VM NAME
# ============================================================================

Write-Section "11. Proposed VM Name"

# The VM name must not already exist.
#
# An existing VM with the requested name is a blocking condition because
# proceeding could cause ambiguity or later deployment failure.

try {

    $ExistingVM = Get-VM `
        -Name $VMName `
        -ErrorAction SilentlyContinue

    if ($ExistingVM) {

        Write-Status `
            -Status "FAIL" `
            -Message "VM '$VMName' already exists."

        Add-CheckResult `
            -Check "VM name availability" `
            -Status "FAIL" `
            -Details "A VM named '$VMName' already exists on this host."
    }
    else {

        Write-Status `
            -Status "PASS" `
            -Message "VM name '$VMName' is available."

        Add-CheckResult `
            -Check "VM name availability" `
            -Status "PASS" `
            -Details "No existing VM named '$VMName' was found."
    }
}
catch {

    Write-Status `
        -Status "FAIL" `
        -Message "Unable to verify VM name availability."

    Add-CheckResult `
        -Check "VM name availability" `
        -Status "FAIL" `
        -Details $_.Exception.Message
}


# ============================================================================
# 12. PROPOSED VHDX DESTINATION FOLDER
# ============================================================================

Write-Section "12. Proposed VHDX Destination Folder"

# Extract the folder containing the proposed VHDX.
#
# Checking this separately is important because Test-Path on the VHDX would
# return False both when:
#
#   - the VHDX correctly does not exist; and
#   - the entire destination folder is missing.

$VHDXFolder = Split-Path `
    -Path $VHDXPath `
    -Parent


if (
    Test-Path `
        -LiteralPath $VHDXFolder `
        -PathType Container
) {

    Write-Status `
        -Status "PASS" `
        -Message "VHDX destination folder exists."

    Write-Host "Path: $VHDXFolder"

    Add-CheckResult `
        -Check "VHDX destination folder" `
        -Status "PASS" `
        -Details "'$VHDXFolder' exists."
}
else {

    Write-Status `
        -Status "FAIL" `
        -Message "VHDX destination folder does not exist."

    Write-Host "Path: $VHDXFolder"

    Add-CheckResult `
        -Check "VHDX destination folder" `
        -Status "FAIL" `
        -Details "'$VHDXFolder' does not exist."
}


# ============================================================================
# 13. PROPOSED VHDX FILE
# ============================================================================

Write-Section "13. Proposed VHDX File"

# For the proposed VM disk, the desired result is that the file does NOT
# already exist.
#
# This protects against accidentally overwriting or attaching an existing
# virtual disk.

if (
    Test-Path `
        -LiteralPath $VHDXPath
) {

    Write-Status `
        -Status "FAIL" `
        -Message "The proposed VHDX already exists."

    Write-Host "Path: $VHDXPath"

    Add-CheckResult `
        -Check "VHDX path availability" `
        -Status "FAIL" `
        -Details "An object already exists at '$VHDXPath'."
}
else {

    Write-Status `
        -Status "PASS" `
        -Message "The proposed VHDX filename is available."

    Write-Host "Path: $VHDXPath"

    Add-CheckResult `
        -Check "VHDX path availability" `
        -Status "PASS" `
        -Details "No existing object found at '$VHDXPath'."
}


# ============================================================================
# 14. INSTALLATION ISO
# ============================================================================

Write-Section "14. Installation ISO"

# Unlike the VHDX, the installation ISO SHOULD already exist.
#
# -PathType Leaf verifies that the supplied path refers to a file.

if (
    Test-Path `
        -LiteralPath $ISOPath `
        -PathType Leaf
) {

    try {

        $ISOFile = Get-Item `
            -LiteralPath $ISOPath `
            -ErrorAction Stop

        $ISOSizeGB = [math]::Round(
            $ISOFile.Length / 1GB,
            2
        )

        Write-Status `
            -Status "PASS" `
            -Message "Installation ISO exists."

        Write-Host "Path: $ISOPath"
        Write-Host "Size: $ISOSizeGB GB"

        Add-CheckResult `
            -Check "Installation ISO" `
            -Status "PASS" `
            -Details "ISO found at '$ISOPath' ($ISOSizeGB GB)."
    }
    catch {

        Write-Status `
            -Status "FAIL" `
            -Message "ISO exists but could not be inspected."

        Add-CheckResult `
            -Check "Installation ISO" `
            -Status "FAIL" `
            -Details $_.Exception.Message
    }
}
else {

    Write-Status `
        -Status "FAIL" `
        -Message "Installation ISO was not found."

    Write-Host "Path: $ISOPath"

    Add-CheckResult `
        -Check "Installation ISO" `
        -Status "FAIL" `
        -Details "Required ISO '$ISOPath' does not exist."
}


# ============================================================================
# 15. LOCAL STORAGE CAPACITY
# ============================================================================

Write-Section "15. Local Storage Capacity"

# Enumerate local fixed volumes.
#
# The script reports capacity across the host because the server is using
# local storage rather than shared cluster storage.

try {

    $Volumes = @(
        Get-Volume `
            -ErrorAction Stop |
        Where-Object {
            $_.DriveType -eq 'Fixed' -and
            $_.DriveLetter
        }
    )


    if ($Volumes.Count -eq 0) {

        Write-Status `
            -Status "FAIL" `
            -Message "No local fixed volumes with drive letters were detected."

        Add-CheckResult `
            -Check "Local storage" `
            -Status "FAIL" `
            -Details "No suitable fixed volumes were returned by Get-Volume."
    }


    foreach ($Volume in $Volumes) {

        $SizeGB = [math]::Round(
            $Volume.Size / 1GB,
            2
        )

        $FreeGB = [math]::Round(
            $Volume.SizeRemaining / 1GB,
            2
        )

        if ($Volume.Size -gt 0) {

            $FreePercent = [math]::Round(
                ($Volume.SizeRemaining / $Volume.Size) * 100,
                1
            )
        }
        else {

            $FreePercent = 0
        }


        Write-Host ""
        Write-Host "Drive        : $($Volume.DriveLetter):"
        Write-Host "Label        : $($Volume.FileSystemLabel)"
        Write-Host "File System  : $($Volume.FileSystem)"
        Write-Host "Health       : $($Volume.HealthStatus)"
        Write-Host "Total        : $SizeGB GB"
        Write-Host "Free         : $FreeGB GB"
        Write-Host "Free Percent : $FreePercent%"


        # Unhealthy volume state is considered blocking.
        if ($Volume.HealthStatus -ne 'Healthy') {

            Add-CheckResult `
                -Check "Volume $($Volume.DriveLetter): health" `
                -Status "FAIL" `
                -Details "Volume health is $($Volume.HealthStatus)."
        }

        # Low capacity requires review.
        elseif (
            $FreePercent -lt $MinimumFreeDiskPercent -or
            $FreeGB -lt $MinimumFreeDiskGB
        ) {

            Add-CheckResult `
                -Check "Volume $($Volume.DriveLetter): capacity" `
                -Status "WARNING" `
                -Details "$FreeGB GB free ($FreePercent%)."
        }

        else {

            Add-CheckResult `
                -Check "Volume $($Volume.DriveLetter): capacity" `
                -Status "PASS" `
                -Details "$FreeGB GB free ($FreePercent%)."
        }
    }
}
catch {

    Write-Status `
        -Status "FAIL" `
        -Message "Unable to retrieve local storage information."

    Add-CheckResult `
        -Check "Local storage" `
        -Status "FAIL" `
        -Details $_.Exception.Message
}


# ============================================================================
# 16. TARGET VHDX VOLUME CAPACITY
# ============================================================================

Write-Section "16. Target VHDX Volume"

# The host-wide disk check is useful, but the volume that will actually
# contain the new VM deserves explicit identification.

try {

    $VHDXDrive = Split-Path `
        -Path $VHDXPath `
        -Qualifier

    if (-not $VHDXDrive) {

        throw "Unable to determine a drive from '$VHDXPath'."
    }

    $DriveLetter = $VHDXDrive.TrimEnd(':').TrimEnd('\')

    $TargetVolume = Get-Volume `
        -DriveLetter $DriveLetter `
        -ErrorAction Stop

    $TargetSizeGB = [math]::Round(
        $TargetVolume.Size / 1GB,
        2
    )

    $TargetFreeGB = [math]::Round(
        $TargetVolume.SizeRemaining / 1GB,
        2
    )

    $TargetFreePercent = [math]::Round(
        ($TargetVolume.SizeRemaining / $TargetVolume.Size) * 100,
        1
    )

    Write-Host "Target Drive : $DriveLetter`:"
    Write-Host "Health       : $($TargetVolume.HealthStatus)"
    Write-Host "Total        : $TargetSizeGB GB"
    Write-Host "Free         : $TargetFreeGB GB"
    Write-Host "Free Percent : $TargetFreePercent%"


    if ($TargetVolume.HealthStatus -ne 'Healthy') {

        Write-Status `
            -Status "FAIL" `
            -Message "The target VM storage volume is not healthy."

        Add-CheckResult `
            -Check "Target VHDX volume" `
            -Status "FAIL" `
            -Details "$DriveLetter`: reports $($TargetVolume.HealthStatus)."
    }
    elseif (
        $TargetFreePercent -lt $MinimumFreeDiskPercent -or
        $TargetFreeGB -lt $MinimumFreeDiskGB
    ) {

        Write-Status `
            -Status "WARNING" `
            -Message "Target VM storage has limited free capacity."

        Add-CheckResult `
            -Check "Target VHDX volume" `
            -Status "WARNING" `
            -Details "$TargetFreeGB GB free ($TargetFreePercent%)."
    }
    else {

        Write-Status `
            -Status "PASS" `
            -Message "Target VM storage volume has acceptable current capacity."

        Add-CheckResult `
            -Check "Target VHDX volume" `
            -Status "PASS" `
            -Details "$TargetFreeGB GB free ($TargetFreePercent%)."
    }
}
catch {

    Write-Status `
        -Status "FAIL" `
        -Message "Unable to validate the target VHDX volume."

    Add-CheckResult `
        -Check "Target VHDX volume" `
        -Status "FAIL" `
        -Details $_.Exception.Message
}


# ============================================================================
# 17. PHYSICAL DISK HEALTH
# ============================================================================

Write-Section "17. Physical Disk Health"

# Physical disk status is particularly important here because the host uses
# local storage and there is no cluster/shared-storage failover path.

try {

    $PhysicalDisks = @(
        Get-PhysicalDisk `
            -ErrorAction Stop
    )


    if ($PhysicalDisks.Count -eq 0) {

        Write-Status `
            -Status "WARNING" `
            -Message "No physical disk information was returned."

        Add-CheckResult `
            -Check "Physical disk health" `
            -Status "WARNING" `
            -Details "Get-PhysicalDisk returned no physical disks."
    }


    foreach ($Disk in $PhysicalDisks) {

        $DiskSizeGB = [math]::Round(
            $Disk.Size / 1GB,
            2
        )

        Write-Host ""
        Write-Host "Disk        : $($Disk.FriendlyName)"
        Write-Host "Media       : $($Disk.MediaType)"
        Write-Host "Bus Type    : $($Disk.BusType)"
        Write-Host "Size        : $DiskSizeGB GB"
        Write-Host "Health      : $($Disk.HealthStatus)"
        Write-Host "Operational : $($Disk.OperationalStatus)"


        if (
            $Disk.HealthStatus -eq 'Healthy' -and
            $Disk.OperationalStatus -contains 'OK'
        ) {

            Add-CheckResult `
                -Check "Physical disk: $($Disk.FriendlyName)" `
                -Status "PASS" `
                -Details "Disk reports Healthy / OK."
        }
        else {

            Add-CheckResult `
                -Check "Physical disk: $($Disk.FriendlyName)" `
                -Status "FAIL" `
                -Details "Health=$($Disk.HealthStatus); Operational=$($Disk.OperationalStatus -join ', ')."
        }
    }
}
catch {

    # Some vendor RAID controllers do not expose meaningful physical disk
    # information to Get-PhysicalDisk.
    #
    # Therefore inability to retrieve these values requires review rather
    # than automatically declaring the host unusable.

    Write-Status `
        -Status "WARNING" `
        -Message "Physical disk health could not be fully queried."

    Add-CheckResult `
        -Check "Physical disk health" `
        -Status "WARNING" `
        -Details $_.Exception.Message
}


# ============================================================================
# 18. STORAGE RELIABILITY COUNTERS
# ============================================================================

Write-Section "18. Storage Reliability Information"

# Windows can expose additional disk reliability information such as:
#
#   - temperature
#   - wear
#   - read errors
#   - write errors
#   - power-on hours
#
# Not every RAID controller or storage device exposes these values.
# Therefore this section is informational.

try {

    $ReliabilityDataFound = $false

    foreach ($Disk in @(Get-PhysicalDisk)) {

        try {

            $Reliability = $Disk |
                Get-StorageReliabilityCounter `
                    -ErrorAction Stop

            $ReliabilityDataFound = $true

            Write-Host ""
            Write-Host "Disk           : $($Disk.FriendlyName)"
            Write-Host "Temperature    : $($Reliability.Temperature)"
            Write-Host "Wear           : $($Reliability.Wear)"
            Write-Host "Read Errors    : $($Reliability.ReadErrorsTotal)"
            Write-Host "Write Errors   : $($Reliability.WriteErrorsTotal)"
            Write-Host "Power-On Hours : $($Reliability.PowerOnHours)"
        }
        catch {

            Write-Host ""
            Write-Host "INFO: Reliability counters unavailable for $($Disk.FriendlyName)."
        }
    }


    if ($ReliabilityDataFound) {

        Add-CheckResult `
            -Check "Storage reliability counters" `
            -Status "INFO" `
            -Details "Reliability information retrieved where supported."
    }
    else {

        Add-CheckResult `
            -Check "Storage reliability counters" `
            -Status "INFO" `
            -Details "No storage reliability counters were available."
    }
}
catch {

    Add-CheckResult `
        -Check "Storage reliability counters" `
        -Status "INFO" `
        -Details "Storage reliability counters are unavailable."
}


# ============================================================================
# 19. HYPER-V DEFAULT STORAGE LOCATIONS
# ============================================================================

Write-Section "19. Hyper-V Default Storage Locations"

try {

    $VMHost = Get-VMHost `
        -ErrorAction Stop

    Write-Host "Default VM Path:"
    Write-Host "  $($VMHost.VirtualMachinePath)"

    Write-Host ""

    Write-Host "Default Virtual Hard Disk Path:"
    Write-Host "  $($VMHost.VirtualHardDiskPath)"


    foreach (
        $Path in @(
            $VMHost.VirtualMachinePath,
            $VMHost.VirtualHardDiskPath
        )
    ) {

        if (
            Test-Path `
                -LiteralPath $Path `
                -PathType Container
        ) {

            Add-CheckResult `
                -Check "Hyper-V path: $Path" `
                -Status "PASS" `
                -Details "Configured Hyper-V path exists."
        }
        else {

            # Default Hyper-V paths being absent should be reviewed, but the
            # proposed VM may deliberately use a different valid VHDX path.

            Add-CheckResult `
                -Check "Hyper-V path: $Path" `
                -Status "WARNING" `
                -Details "Configured Hyper-V default path does not exist."
        }
    }
}
catch {

    Add-CheckResult `
        -Check "Hyper-V default storage locations" `
        -Status "WARNING" `
        -Details "Unable to validate Hyper-V default storage paths."
}


# ============================================================================
# 20. EXISTING VM DISK LOCATIONS
# ============================================================================

Write-Section "20. Existing VM Disk Locations"

try {

    $VMHardDisks = @(
        Get-VM |
        Get-VMHardDiskDrive `
            -ErrorAction SilentlyContinue
    )

    if ($VMHardDisks.Count -gt 0) {

        $VMHardDisks |
            Select-Object `
                VMName,
                ControllerType,
                ControllerNumber,
                ControllerLocation,
                Path |
            Format-Table -AutoSize
    }
    else {

        Write-Status `
            -Status "INFO" `
            -Message "No existing VM hard disks were returned."
    }

    Add-CheckResult `
        -Check "Existing VM disk locations" `
        -Status "INFO" `
        -Details "Existing VM disk locations enumerated."
}
catch {

    Add-CheckResult `
        -Check "Existing VM disk locations" `
        -Status "WARNING" `
        -Details "Unable to enumerate existing VM disk locations."
}


# ============================================================================
# 21. HYPER-V VIRTUAL SWITCHES
# ============================================================================

Write-Section "21. Hyper-V Virtual Switches"

# IMPORTANT:
#
# Networking is intentionally deferred in this build process.
#
# Therefore:
#
#   NO VIRTUAL SWITCH
#
# is an expected state and MUST NOT block the build.
#
# If one or more switches already exist, they are simply reported for
# information.

try {

    $VMSwitches = @(
        Get-VMSwitch `
            -ErrorAction Stop
    )

    if ($VMSwitches.Count -eq 0) {

        if ($NetworkingDeferred) {

            Write-Status `
                -Status "INFO" `
                -Message "No Hyper-V virtual switches exist. This is expected because networking is deferred."

            Add-CheckResult `
                -Check "Hyper-V virtual switches" `
                -Status "INFO" `
                -Details "No virtual switches found; networking is intentionally deferred and this does not block the VM build."
        }
        else {

            # This branch remains here to make the intent of the logic clear,
            # although NetworkingDeferred is currently statically set to True.

            Write-Status `
                -Status "WARNING" `
                -Message "No Hyper-V virtual switches exist."

            Add-CheckResult `
                -Check "Hyper-V virtual switches" `
                -Status "WARNING" `
                -Details "No virtual switches found."
        }
    }
    else {

        $VMSwitches |
            Select-Object `
                Name,
                SwitchType,
                NetAdapterInterfaceDescription,
                AllowManagementOS |
            Format-Table -AutoSize

        Add-CheckResult `
            -Check "Hyper-V virtual switches" `
            -Status "INFO" `
            -Details "$($VMSwitches.Count) existing virtual switch(es) found; networking remains outside the current VM build scope."
    }
}
catch {

    Write-Status `
        -Status "WARNING" `
        -Message "Unable to enumerate Hyper-V virtual switches."

    Add-CheckResult `
        -Check "Hyper-V virtual switches" `
        -Status "WARNING" `
        -Details $_.Exception.Message
}


# ============================================================================
# 22. PHYSICAL NETWORK ADAPTERS
# ============================================================================

Write-Section "22. Physical Network Adapters"

# Physical NIC state is recorded for awareness.
#
# Because VM networking is intentionally deferred, an unused/down adapter
# does not automatically prevent creation of the VM.

try {

    $Adapters = @(
        Get-NetAdapter `
            -Physical `
            -ErrorAction Stop
    )

    if ($Adapters.Count -gt 0) {

        $Adapters |
            Select-Object `
                Name,
                InterfaceDescription,
                Status,
                LinkSpeed,
                MacAddress |
            Format-Table -AutoSize

        $UpAdapters = @(
            $Adapters |
            Where-Object Status -eq 'Up'
        )

        if ($UpAdapters.Count -gt 0) {

            Add-CheckResult `
                -Check "Physical network adapters" `
                -Status "INFO" `
                -Details "$($UpAdapters.Count) of $($Adapters.Count) physical adapters currently report Up; VM networking is deferred."
        }
        else {

            Add-CheckResult `
                -Check "Physical network adapters" `
                -Status "INFO" `
                -Details "No physical NICs currently report Up; VM networking is intentionally deferred."
        }
    }
    else {

        Add-CheckResult `
            -Check "Physical network adapters" `
            -Status "INFO" `
            -Details "No physical adapters returned; VM networking is intentionally deferred."
    }
}
catch {

    Add-CheckResult `
        -Check "Physical network adapters" `
        -Status "INFO" `
        -Details "Physical network adapter information unavailable; networking is outside the current build scope."
}


# ============================================================================
# 23. EXISTING VM CHECKPOINTS
# ============================================================================

Write-Section "23. Existing VM Checkpoints"

# Existing checkpoints can consume local disk capacity and may indicate
# incomplete maintenance or backup activity.
#
# Their presence therefore requires review, but does not automatically
# prevent creation of another VM.

try {

    $Snapshots = @(
        Get-VM |
        Get-VMSnapshot `
            -ErrorAction SilentlyContinue
    )

    if ($Snapshots.Count -gt 0) {

        Write-Status `
            -Status "WARNING" `
            -Message "Existing VM checkpoints were found."

        $Snapshots |
            Select-Object `
                VMName,
                Name,
                SnapshotType,
                CreationTime |
            Format-Table -AutoSize

        Add-CheckResult `
            -Check "Existing VM checkpoints" `
            -Status "WARNING" `
            -Details "$($Snapshots.Count) checkpoint(s) currently exist and should be reviewed."
    }
    else {

        Write-Status `
            -Status "PASS" `
            -Message "No existing VM checkpoints were found."

        Add-CheckResult `
            -Check "Existing VM checkpoints" `
            -Status "PASS" `
            -Details "No existing VM checkpoints found."
    }
}
catch {

    Add-CheckResult `
        -Check "Existing VM checkpoints" `
        -Status "WARNING" `
        -Details "Unable to query existing VM checkpoints."
}


# ============================================================================
# 24. RECENT WINDOWS SYSTEM ERRORS
# ============================================================================

Write-Section "24. Recent Windows System Errors"

$StartTime = (Get-Date).AddDays(
    -$EventLogLookbackDays
)

try {

    $SystemErrors = @(
        Get-WinEvent `
            -FilterHashtable @{
                LogName   = 'System'
                Level     = 1,2
                StartTime = $StartTime
            } `
            -ErrorAction Stop |
        Select-Object `
            -First $MaximumEventsToDisplay
    )


    if ($SystemErrors.Count -gt 0) {

        Write-Status `
            -Status "WARNING" `
            -Message "Recent Critical/Error System events were found."

        Write-Host ""

        $SystemErrors |
            Select-Object `
                TimeCreated,
                ProviderName,
                Id,
                LevelDisplayName,
                Message |
            Format-Table -Wrap

        Add-CheckResult `
            -Check "Recent System errors" `
            -Status "WARNING" `
            -Details "Recent Critical/Error System events require interpretation before the build."
    }
    else {

        Write-Status `
            -Status "PASS" `
            -Message "No Critical/Error System events were found in the lookback period."

        Add-CheckResult `
            -Check "Recent System errors" `
            -Status "PASS" `
            -Details "No Critical/Error System events found during the last $EventLogLookbackDays days."
    }
}
catch {

    Write-Status `
        -Status "WARNING" `
        -Message "Unable to query the Windows System event log."

    Add-CheckResult `
        -Check "Recent System errors" `
        -Status "WARNING" `
        -Details $_.Exception.Message
}


# ============================================================================
# 25. RECENT HYPER-V VMMS ERRORS
# ============================================================================

Write-Section "25. Recent Hyper-V VMMS Errors"

$VMMSLog = 'Microsoft-Windows-Hyper-V-VMMS-Admin'

try {

    $HyperVErrors = @(
        Get-WinEvent `
            -FilterHashtable @{
                LogName   = $VMMSLog
                Level     = 1,2
                StartTime = $StartTime
            } `
            -ErrorAction Stop |
        Select-Object `
            -First $MaximumEventsToDisplay
    )


    if ($HyperVErrors.Count -gt 0) {

        Write-Status `
            -Status "WARNING" `
            -Message "Recent Hyper-V VMMS errors were found."

        Write-Host ""

        $HyperVErrors |
            Select-Object `
                TimeCreated,
                Id,
                LevelDisplayName,
                Message |
            Format-Table -Wrap

        Add-CheckResult `
            -Check "Recent Hyper-V VMMS errors" `
            -Status "WARNING" `
            -Details "Recent Hyper-V errors require interpretation before the build."
    }
    else {

        Write-Status `
            -Status "PASS" `
            -Message "No recent Hyper-V VMMS Critical/Error events were found."

        Add-CheckResult `
            -Check "Recent Hyper-V VMMS errors" `
            -Status "PASS" `
            -Details "No Critical/Error VMMS events found during the last $EventLogLookbackDays days."
    }
}
catch {

    Write-Status `
        -Status "WARNING" `
        -Message "Unable to query the Hyper-V VMMS event log."

    Add-CheckResult `
        -Check "Recent Hyper-V VMMS errors" `
        -Status "WARNING" `
        -Details $_.Exception.Message
}


# ============================================================================
# 26. RECENT STORAGE-RELATED EVENTS
# ============================================================================

Write-Section "26. Recent Storage-Related Events"

# Since the VM resides on local storage, storage-stack errors deserve
# particular attention.
#
# Historical events still require human interpretation because an error
# may already have been resolved.

$StorageProviders = @(
    'disk',
    'Ntfs',
    'storahci',
    'stornvme',
    'storport',
    'Microsoft-Windows-StorPort',
    'Microsoft-Windows-Storage-ClassPnP'
)

try {

    $StorageEvents = @(
        Get-WinEvent `
            -FilterHashtable @{
                LogName   = 'System'
                Level     = 1,2,3
                StartTime = $StartTime
            } `
            -ErrorAction Stop |
        Where-Object {
            $_.ProviderName -in $StorageProviders
        } |
        Select-Object `
            -First $MaximumEventsToDisplay
    )


    if ($StorageEvents.Count -gt 0) {

        Write-Status `
            -Status "WARNING" `
            -Message "Recent storage-related events were detected."

        Write-Host ""

        $StorageEvents |
            Select-Object `
                TimeCreated,
                ProviderName,
                Id,
                LevelDisplayName,
                Message |
            Format-Table -Wrap

        Add-CheckResult `
            -Check "Storage event log" `
            -Status "WARNING" `
            -Details "Storage-related warning/error events require review."
    }
    else {

        Write-Status `
            -Status "PASS" `
            -Message "No matching recent storage warnings/errors were found."

        Add-CheckResult `
            -Check "Storage event log" `
            -Status "PASS" `
            -Details "No matching storage events found during the last $EventLogLookbackDays days."
    }
}
catch {

    Add-CheckResult `
        -Check "Storage event log" `
        -Status "WARNING" `
        -Details "Unable to query storage-related System events."
}


# ============================================================================
# 27. FINAL RESULT SUMMARY
# ============================================================================

Write-Section "27. Host and VM Build Readiness Summary"

# Show every check so the operator can see exactly why the overall result
# was reached.

$Results |
    Format-Table `
        Check,
        Status,
        Details `
        -Wrap `
        -AutoSize


# ============================================================================
# COUNT RESULTS
# ============================================================================

$PassCount = @(
    $Results |
    Where-Object Status -eq 'PASS'
).Count

$InfoCount = @(
    $Results |
    Where-Object Status -eq 'INFO'
).Count

$WarningCount = @(
    $Results |
    Where-Object Status -eq 'WARNING'
).Count

$FailCount = @(
    $Results |
    Where-Object Status -eq 'FAIL'
).Count


Write-Host ""
Write-Host "PASS    : $PassCount"
Write-Host "INFO    : $InfoCount"
Write-Host "WARNING : $WarningCount"
Write-Host "FAIL    : $FailCount"
Write-Host ""


# ============================================================================
# 28. FINAL BUILD DECISION
# ============================================================================

# FAIL
#
# Any FAIL represents a condition that should prevent the VM build.
#
# Examples include:
#
#   - Hyper-V unavailable
#   - VMMS not running
#   - VM name already exists
#   - VHDX already exists
#   - VHDX destination directory missing
#   - required ISO missing
#   - unhealthy target volume
#   - unhealthy physical disk
#
# WARNING
#
# Warnings require interpretation rather than automatically blocking the
# build.
#
# Examples include:
#
#   - pending reboot
#   - high short-term CPU utilisation
#   - limited memory headroom
#   - low disk capacity
#   - historical event log errors
#   - existing checkpoints
#
# INFO
#
# Information does not affect the build decision.
#
# In particular:
#
#   No Hyper-V virtual switch is INFO because networking is intentionally
#   deferred in this build process.


if ($FailCount -gt 0) {

    Write-Host "============================================================"
    Write-Host "RESULT: FAIL - DO NOT BUILD VM"
    Write-Host "============================================================"
    Write-Host ""

    Write-Host "One or more blocking conditions were detected."
    Write-Host ""
    Write-Host "Resolve the FAIL item(s) before creating '$VMName'."

    $ExitCode = 2
}
elseif ($WarningCount -gt 0) {

    Write-Host "============================================================"
    Write-Host "RESULT: REVIEW - BUILD REQUIRES INTERPRETATION"
    Write-Host "============================================================"
    Write-Host ""

    Write-Host "No automatic build blockers were detected."
    Write-Host ""
    Write-Host "One or more WARNING items require review before proceeding."
    Write-Host ""
    Write-Host "NOTE:"
    Write-Host "The absence of a Hyper-V virtual switch is NOT a blocker."
    Write-Host "Networking is intentionally deferred for this build."

    $ExitCode = 1
}
else {

    Write-Host "============================================================"
    Write-Host "RESULT: PASS - HOST SUITABLE FOR VM BUILD"
    Write-Host "============================================================"
    Write-Host ""

    Write-Host "No blocking conditions or review warnings were detected."
    Write-Host ""
    Write-Host "The host appears suitable for creation of '$VMName'."
    Write-Host ""
    Write-Host "Networking remains intentionally deferred."

    $ExitCode = 0
}


# ============================================================================
# 29. EXIT CODE
# ============================================================================

# Exit codes:
#
#   0 = PASS
#   1 = REVIEW
#   2 = FAIL
#
# If you are running this interactively and do not want the script to
# terminate the PowerShell session, comment out the following line.

exit $ExitCode
