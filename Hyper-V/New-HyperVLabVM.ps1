<#
.SYNOPSIS
    Creates and validates a standard Generation 2 Hyper-V lab VM.

.DESCRIPTION
    Builds a reusable Generation 2 VM on a standalone Windows Server
    Hyper-V host.

    The workflow consists of five stages:

        Stage 1 - Pre-Build Validation
            - Verify administrative privileges
            - Verify Hyper-V availability
            - Verify VMMS service
            - Detect VM name collisions
            - Validate VHDX destination folder
            - Detect VHDX collisions
            - Validate installation ISO
            - Validate target storage volume
            - Detect desired-state PSD1 collisions

        Stage 2 - VM Shell
            - Create Generation 2 VM
            - Configure startup memory
            - Configure processor count
            - Disable Dynamic Memory
            - Validate VM shell

        Stage 3 - Virtual Disk
            - Create dynamically expanding VHDX
            - Validate VHDX format, type and size
            - Attach OS disk at SCSI 0:0
            - Validate disk attachment

        Stage 4 - Installation Media and Firmware
            - Attach ISO at SCSI 0:1
            - Validate DVD attachment
            - Enable Secure Boot
            - Apply MicrosoftWindows Secure Boot template
            - Configure DVD as first boot device
            - Validate firmware state

        Stage 5 - Desired State and Drift Validation
            - Create desired-state configuration directory if required
            - Write VM desired-state PSD1 from REQUESTED build values
            - Validate the PSD1 can be imported
            - Run Test-HyperVVMConfiguration.ps1
            - Require a clean expected-vs-actual validation result

    This version DOES NOT:
        - Install Windows automatically
        - Start the VM
        - Configure VM networking
        - Create checkpoints

    Networking is intentionally deferred.

    IMPORTANT:
        The script does not automatically remove partially created resources
        if a later stage fails.

        This is deliberate.

        If a stage fails, inspect the resulting VM, disk and configuration
        state before deciding what should be removed.

.NOTES
    Intended for:
        - Windows Server Hyper-V
        - Standalone Hyper-V hosts
        - Local VM storage
        - Generation 2 Windows lab VMs

    Run from an elevated PowerShell session.

    The drift validator is expected at:
        <script directory>\Test-HyperVVMConfiguration.ps1

.EXAMPLE
    .\New-HyperVLabVM.ps1 `
        -VMName "LAB-APP01" `
        -ProcessorCount 2 `
        -StartupMemoryGB 4 `
        -VHDSizeGB 60 `
        -VHDXPath "D:\Hyper-V\Virtual Hard Disks\LAB-APP01.vhdx" `
        -ISOPath "D:\Hyper-V\ISOs\WinServer2025.ISO"
#>


# ============================================================================
# PARAMETERS
# ============================================================================

[CmdletBinding()]
param (

    # Name of the new Hyper-V virtual machine.
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$VMName,


    # Number of virtual processors.
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 64)]
    [int]$ProcessorCount,


    # Static startup memory in GB.
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 1024)]
    [int]$StartupMemoryGB,


    # Maximum virtual size of the dynamic VHDX in GB.
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 65536)]
    [int]$VHDSizeGB,


    # Full path for the new VHDX.
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$VHDXPath,


    # Full path to the Windows installation ISO.
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ISOPath
)


# ============================================================================
# STATIC BUILD DEFAULTS
# ============================================================================

# Current lab standard uses Generation 2 VMs.
$Generation = 2


# Current lab standard uses static memory.
$DynamicMemoryEnabled = $false


# OS disk is dynamically expanding.
$VHDType = "Dynamic"


# Generation 2 Windows firmware standard.
$SecureBootEnabled = $true

$SecureBootTemplate = "MicrosoftWindows"


# Networking is intentionally deferred.
#
# Empty string means that no Hyper-V switch connection is expected.
$ExpectedSwitchName = ""


# A newly built clean VM should contain no checkpoints.
$ExpectedCheckpointCount = 0


# Machine-readable desired-state files are stored here.
$ConfigFolder = "C:\HyperV-Baselines\Config"


# ============================================================================
# RESULT COLLECTION
# ============================================================================

$Results = @()


function Add-PreBuildResult {

    <#
    .SYNOPSIS
        Adds one result to the Stage 1 validation collection.
    #>

    param (

        [Parameter(Mandatory)]
        [string]$Check,

        [Parameter(Mandatory)]
        [ValidateSet(
            'PASS',
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
# SCRIPT HEADER
# ============================================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "Hyper-V Lab VM Build"
Write-Host "============================================================"
Write-Host ""

Write-Host "Host             : $env:COMPUTERNAME"
Write-Host "VM Name          : $VMName"
Write-Host "Generation       : $Generation"
Write-Host "Processor Count  : $ProcessorCount"
Write-Host "Startup Memory   : $StartupMemoryGB GB"
Write-Host "VHDX Size        : $VHDSizeGB GB"
Write-Host "VHDX Path        : $VHDXPath"
Write-Host "ISO Path         : $ISOPath"
Write-Host "Networking       : Deferred"
Write-Host "Date             : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ""


# ============================================================================
# STAGE 1 - PRE-BUILD VALIDATION
# ============================================================================

Write-Host "============================================================"
Write-Host "Stage 1 - Pre-Build Validation"
Write-Host "============================================================"
Write-Host ""


# ============================================================================
# 1. ADMINISTRATIVE PRIVILEGES
# ============================================================================

$CurrentIdentity =
    [Security.Principal.WindowsIdentity]::GetCurrent()


$Principal = New-Object `
    Security.Principal.WindowsPrincipal($CurrentIdentity)


$IsAdministrator = $Principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)


if ($IsAdministrator) {

    Add-PreBuildResult `
        -Check "Administrative privileges" `
        -Status "PASS" `
        -Details "PowerShell is running elevated."
}
else {

    Add-PreBuildResult `
        -Check "Administrative privileges" `
        -Status "FAIL" `
        -Details "PowerShell must be run as Administrator."
}


# ============================================================================
# 2. HYPER-V AVAILABILITY
# ============================================================================

if (
    Get-Command `
        -Name Get-VMHost `
        -ErrorAction SilentlyContinue
) {

    try {

        $null = Get-VMHost `
            -ErrorAction Stop


        Add-PreBuildResult `
            -Check "Hyper-V availability" `
            -Status "PASS" `
            -Details "Hyper-V host successfully queried."
    }
    catch {

        Add-PreBuildResult `
            -Check "Hyper-V availability" `
            -Status "FAIL" `
            -Details $_.Exception.Message
    }
}
else {

    Add-PreBuildResult `
        -Check "Hyper-V availability" `
        -Status "FAIL" `
        -Details "Get-VMHost is unavailable."
}


# ============================================================================
# 3. VMMS SERVICE
# ============================================================================

try {

    $VMMS = Get-Service `
        -Name vmms `
        -ErrorAction Stop


    if ($VMMS.Status -eq 'Running') {

        Add-PreBuildResult `
            -Check "VMMS service" `
            -Status "PASS" `
            -Details "VMMS is running."
    }
    else {

        Add-PreBuildResult `
            -Check "VMMS service" `
            -Status "FAIL" `
            -Details "VMMS state is $($VMMS.Status)."
    }
}
catch {

    Add-PreBuildResult `
        -Check "VMMS service" `
        -Status "FAIL" `
        -Details "Unable to query VMMS."
}


# ============================================================================
# 4. VM NAME COLLISION
# ============================================================================

try {

    $ExistingVM = Get-VM `
        -Name $VMName `
        -ErrorAction SilentlyContinue


    if ($ExistingVM) {

        Add-PreBuildResult `
            -Check "VM name availability" `
            -Status "FAIL" `
            -Details "A VM named '$VMName' already exists."
    }
    else {

        Add-PreBuildResult `
            -Check "VM name availability" `
            -Status "PASS" `
            -Details "VM name '$VMName' is available."
    }
}
catch {

    Add-PreBuildResult `
        -Check "VM name availability" `
        -Status "FAIL" `
        -Details $_.Exception.Message
}


# ============================================================================
# 5. VHDX DESTINATION FOLDER
# ============================================================================

$VHDXFolder = Split-Path `
    -Path $VHDXPath `
    -Parent


if (
    Test-Path `
        -LiteralPath $VHDXFolder `
        -PathType Container
) {

    Add-PreBuildResult `
        -Check "VHDX destination folder" `
        -Status "PASS" `
        -Details "'$VHDXFolder' exists."
}
else {

    Add-PreBuildResult `
        -Check "VHDX destination folder" `
        -Status "FAIL" `
        -Details "'$VHDXFolder' does not exist."
}


# ============================================================================
# 6. VHDX COLLISION
# ============================================================================

if (Test-Path -LiteralPath $VHDXPath) {

    Add-PreBuildResult `
        -Check "VHDX path availability" `
        -Status "FAIL" `
        -Details "An object already exists at '$VHDXPath'."
}
else {

    Add-PreBuildResult `
        -Check "VHDX path availability" `
        -Status "PASS" `
        -Details "VHDX filename is available."
}


# ============================================================================
# 7. INSTALLATION ISO
# ============================================================================

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


        Add-PreBuildResult `
            -Check "Installation ISO" `
            -Status "PASS" `
            -Details "ISO exists ($ISOSizeGB GB)."
    }
    catch {

        Add-PreBuildResult `
            -Check "Installation ISO" `
            -Status "FAIL" `
            -Details $_.Exception.Message
    }
}
else {

    Add-PreBuildResult `
        -Check "Installation ISO" `
        -Status "FAIL" `
        -Details "Required ISO '$ISOPath' does not exist."
}


# ============================================================================
# 8. TARGET STORAGE VOLUME
# ============================================================================

try {

    $VHDXDrive = Split-Path `
        -Path $VHDXPath `
        -Qualifier


    if (-not $VHDXDrive) {

        throw "Unable to determine target drive from '$VHDXPath'."
    }


    $DriveLetter =
        $VHDXDrive.TrimEnd(':').TrimEnd('\')


    $TargetVolume = Get-Volume `
        -DriveLetter $DriveLetter `
        -ErrorAction Stop


    $FreeGB = [math]::Round(
        $TargetVolume.SizeRemaining / 1GB,
        2
    )


    if ($TargetVolume.HealthStatus -eq 'Healthy') {

        Add-PreBuildResult `
            -Check "Target storage volume" `
            -Status "PASS" `
            -Details "$DriveLetter`: is Healthy with $FreeGB GB free."
    }
    else {

        Add-PreBuildResult `
            -Check "Target storage volume" `
            -Status "FAIL" `
            -Details "$DriveLetter`: health is $($TargetVolume.HealthStatus)."
    }
}
catch {

    Add-PreBuildResult `
        -Check "Target storage volume" `
        -Status "FAIL" `
        -Details $_.Exception.Message
}


# ============================================================================
# 9. DESIRED-STATE CONFIG COLLISION
# ============================================================================

$ConfigPath = Join-Path `
    -Path $ConfigFolder `
    -ChildPath "$VMName.psd1"


if (Test-Path -LiteralPath $ConfigPath) {

    Add-PreBuildResult `
        -Check "Desired-state config" `
        -Status "FAIL" `
        -Details "Baseline file '$ConfigPath' already exists."
}
else {

    Add-PreBuildResult `
        -Check "Desired-state config" `
        -Status "PASS" `
        -Details "Baseline filename is available."
}


# ============================================================================
# 10. DISPLAY PRE-BUILD RESULTS
# ============================================================================

Write-Host "=== PRE-BUILD RESULTS ==="
Write-Host ""


$Results |
    Format-Table `
        Check,
        Status,
        Details `
        -AutoSize `
        -Wrap


# ============================================================================
# 11. PRE-BUILD DECISION
# ============================================================================

$PassCount = @(
    $Results |
    Where-Object Status -eq 'PASS'
).Count


$FailCount = @(
    $Results |
    Where-Object Status -eq 'FAIL'
).Count


Write-Host ""
Write-Host "PASS : $PassCount"
Write-Host "FAIL : $FailCount"
Write-Host ""


if ($FailCount -gt 0) {

    Write-Host "============================================================"
    Write-Host "RESULT: FAIL - VM BUILD MUST NOT START"
    Write-Host "============================================================"
    Write-Host ""
    Write-Host "Resolve the failed pre-build checks before continuing."

    $global:LASTEXITCODE = 2
    return
}


Write-Host "============================================================"
Write-Host "RESULT: PASS - PRE-BUILD CHECKS COMPLETE"
Write-Host "============================================================"
Write-Host ""
Write-Host "No blocking pre-build conditions were detected."


# ============================================================================
# STAGE 2 - CREATE VM SHELL
# ============================================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "Stage 2 - Create VM Shell"
Write-Host "============================================================"
Write-Host ""


# ============================================================================
# 12. CREATE GENERATION 2 VM
# ============================================================================

try {

    $NewVM = New-VM `
        -Name $VMName `
        -Generation $Generation `
        -MemoryStartupBytes ($StartupMemoryGB * 1GB) `
        -NoVHD `
        -ErrorAction Stop


    Write-Host "PASS: VM shell created successfully."
}
catch {

    Write-Host "FAIL: VM shell could not be created."
    Write-Host ""
    Write-Host $_.Exception.Message

    $global:LASTEXITCODE = 2
    return
}


# ============================================================================
# 13. CONFIGURE PROCESSOR COUNT
# ============================================================================

try {

    Set-VMProcessor `
        -VMName $VMName `
        -Count $ProcessorCount `
        -ErrorAction Stop


    Write-Host "PASS: Processor count configured."
}
catch {

    Write-Host "FAIL: Unable to configure processor count."
    Write-Host ""
    Write-Host $_.Exception.Message
    Write-Host ""
    Write-Host "NOTE: A partial VM now exists."
    Write-Host "Review the VM before performing cleanup."

    $global:LASTEXITCODE = 2
    return
}


# ============================================================================
# 14. CONFIGURE DYNAMIC MEMORY
# ============================================================================

try {

    Set-VMMemory `
        -VMName $VMName `
        -DynamicMemoryEnabled $DynamicMemoryEnabled `
        -ErrorAction Stop


    Write-Host "PASS: Dynamic Memory state configured."
}
catch {

    Write-Host "FAIL: Unable to configure VM memory settings."
    Write-Host ""
    Write-Host $_.Exception.Message
    Write-Host ""
    Write-Host "NOTE: A partial VM now exists."
    Write-Host "Review the VM before performing cleanup."

    $global:LASTEXITCODE = 2
    return
}


# ============================================================================
# 15. VALIDATE VM SHELL
# ============================================================================

try {

    $VMValidation = Get-VM `
        -Name $VMName `
        -ErrorAction Stop


    Write-Host ""
    Write-Host "=== VM SHELL VALIDATION ==="
    Write-Host ""


    $VMValidation |
        Select-Object `
            Name,
            State,
            Status,
            Generation,
            ProcessorCount,
            @{
                Name = 'MemoryStartupGB'
                Expression = {
                    [math]::Round(
                        $_.MemoryStartup / 1GB,
                        2
                    )
                }
            },
            DynamicMemoryEnabled |
        Format-List


    $ShellValid = (
        $VMValidation.Generation -eq $Generation -and
        $VMValidation.ProcessorCount -eq $ProcessorCount -and
        $VMValidation.MemoryStartup -eq ($StartupMemoryGB * 1GB) -and
        $VMValidation.DynamicMemoryEnabled -eq $DynamicMemoryEnabled
    )


    if (-not $ShellValid) {

        Write-Host ""
        Write-Host "============================================================"
        Write-Host "RESULT: FAIL - VM SHELL VALIDATION FAILED"
        Write-Host "============================================================"
        Write-Host ""
        Write-Host "The VM exists but does not match the requested configuration."

        $global:LASTEXITCODE = 2
        return
    }


    Write-Host "PASS: VM shell matches requested configuration."
}
catch {

    Write-Host ""
    Write-Host "FAIL: Unable to validate the VM shell."
    Write-Host ""
    Write-Host $_.Exception.Message

    $global:LASTEXITCODE = 2
    return
}


# ============================================================================
# STAGE 3 - CREATE AND ATTACH VHDX
# ============================================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "Stage 3 - Create and Attach VHDX"
Write-Host "============================================================"
Write-Host ""


# ============================================================================
# 16. VERIFY VM IS OFF
# ============================================================================

try {

    $VMValidation = Get-VM `
        -Name $VMName `
        -ErrorAction Stop
}
catch {

    Write-Host "FAIL: Unable to query VM before storage configuration."
    Write-Host ""
    Write-Host $_.Exception.Message

    $global:LASTEXITCODE = 2
    return
}


if ($VMValidation.State -ne 'Off') {

    Write-Host "FAIL: VM is not powered off."
    Write-Host "Current State: $($VMValidation.State)"

    $global:LASTEXITCODE = 2
    return
}


Write-Host "PASS: VM is powered off."


# ============================================================================
# 17. RECHECK VHDX PATH
# ============================================================================

if (Test-Path -LiteralPath $VHDXPath) {

    Write-Host "FAIL: VHDX already exists."
    Write-Host "Path: $VHDXPath"

    $global:LASTEXITCODE = 2
    return
}


Write-Host "PASS: VHDX path remains available."


# ============================================================================
# 18. CREATE DYNAMIC VHDX
# ============================================================================

try {

    $NewVHD = New-VHD `
        -Path $VHDXPath `
        -SizeBytes ($VHDSizeGB * 1GB) `
        -Dynamic `
        -ErrorAction Stop


    Write-Host "PASS: Dynamic VHDX created successfully."
}
catch {

    Write-Host "FAIL: Unable to create VHDX."
    Write-Host ""
    Write-Host $_.Exception.Message
    Write-Host ""
    Write-Host "NOTE: The VM shell already exists."
    Write-Host "Review existing resources before cleanup."

    $global:LASTEXITCODE = 2
    return
}


# ============================================================================
# 19. VALIDATE VHDX
# ============================================================================

try {

    $VHDValidation = Get-VHD `
        -Path $VHDXPath `
        -ErrorAction Stop


    $ActualVHDSizeGB = [math]::Round(
        $VHDValidation.Size / 1GB,
        2
    )


    Write-Host ""
    Write-Host "=== VHDX VALIDATION ==="
    Write-Host ""


    $VHDValidation |
        Select-Object `
            Path,
            VhdFormat,
            VhdType,
            @{
                Name = 'MaximumSizeGB'
                Expression = {
                    [math]::Round(
                        $_.Size / 1GB,
                        2
                    )
                }
            },
            @{
                Name = 'CurrentFileSizeMB'
                Expression = {
                    [math]::Round(
                        $_.FileSize / 1MB,
                        2
                    )
                }
            } |
        Format-List


    $VHDValid = (
        $VHDValidation.VhdFormat -eq 'VHDX' -and
        $VHDValidation.VhdType -eq $VHDType -and
        $ActualVHDSizeGB -eq $VHDSizeGB
    )


    if (-not $VHDValid) {

        Write-Host "FAIL: Created VHDX does not match requested configuration."
        Write-Host ""
        Write-Host "Expected Type : $VHDType"
        Write-Host "Actual Type   : $($VHDValidation.VhdType)"
        Write-Host "Expected Size : $VHDSizeGB GB"
        Write-Host "Actual Size   : $ActualVHDSizeGB GB"

        $global:LASTEXITCODE = 2
        return
    }


    Write-Host "PASS: VHDX properties match requested configuration."
}
catch {

    Write-Host "FAIL: Unable to validate the new VHDX."
    Write-Host ""
    Write-Host $_.Exception.Message

    $global:LASTEXITCODE = 2
    return
}


# ============================================================================
# 20. CONFIRM SCSI 0:0 IS AVAILABLE
# ============================================================================

try {

    $ExistingLocation = @(
        Get-VMHardDiskDrive `
            -VMName $VMName `
            -ErrorAction Stop |
        Where-Object {
            $_.ControllerType -eq 'SCSI' -and
            $_.ControllerNumber -eq 0 -and
            $_.ControllerLocation -eq 0
        }
    )


    if ($ExistingLocation.Count -gt 0) {

        Write-Host "FAIL: SCSI controller 0, location 0 is already occupied."

        $global:LASTEXITCODE = 2
        return
    }


    Write-Host "PASS: SCSI controller 0, location 0 is available."
}
catch {

    Write-Host "FAIL: Unable to inspect existing VM disk attachments."
    Write-Host ""
    Write-Host $_.Exception.Message

    $global:LASTEXITCODE = 2
    return
}


# ============================================================================
# 21. ATTACH VHDX
# ============================================================================

try {

    Add-VMHardDiskDrive `
        -VMName $VMName `
        -ControllerType SCSI `
        -ControllerNumber 0 `
        -ControllerLocation 0 `
        -Path $VHDXPath `
        -ErrorAction Stop


    Write-Host "PASS: VHDX attached to VM."
}
catch {

    Write-Host "FAIL: Unable to attach VHDX."
    Write-Host ""
    Write-Host $_.Exception.Message
    Write-Host ""
    Write-Host "NOTE: The VHDX exists but may not be attached."

    $global:LASTEXITCODE = 2
    return
}


# ============================================================================
# 22. VALIDATE VHDX ATTACHMENT
# ============================================================================

try {

    $AttachedDisk = Get-VMHardDiskDrive `
        -VMName $VMName `
        -ErrorAction Stop |
        Where-Object {
            $_.Path -eq $VHDXPath
        } |
        Select-Object -First 1


    if (-not $AttachedDisk) {

        throw "Expected VHDX is not attached to '$VMName'."
    }


    Write-Host ""
    Write-Host "=== VHDX ATTACHMENT VALIDATION ==="
    Write-Host ""


    $AttachedDisk |
        Select-Object `
            VMName,
            ControllerType,
            ControllerNumber,
            ControllerLocation,
            Path |
        Format-List


    $AttachmentValid = (
        $AttachedDisk.ControllerType -eq 'SCSI' -and
        $AttachedDisk.ControllerNumber -eq 0 -and
        $AttachedDisk.ControllerLocation -eq 0 -and
        $AttachedDisk.Path -eq $VHDXPath
    )


    if (-not $AttachmentValid) {

        Write-Host "FAIL: VHDX attachment does not match expected configuration."

        $global:LASTEXITCODE = 2
        return
    }


    Write-Host "PASS: VHDX attachment matches requested configuration."
}
catch {

    Write-Host "FAIL: Unable to validate VHDX attachment."
    Write-Host ""
    Write-Host $_.Exception.Message

    $global:LASTEXITCODE = 2
    return
}


# ============================================================================
# STAGE 4 - INSTALLATION MEDIA AND FIRMWARE
# ============================================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "Stage 4 - Installation Media and Firmware"
Write-Host "============================================================"
Write-Host ""


# ============================================================================
# 23. VERIFY VM REMAINS OFF
# ============================================================================

try {

    $VMValidation = Get-VM `
        -Name $VMName `
        -ErrorAction Stop
}
catch {

    Write-Host "FAIL: Unable to query VM before firmware configuration."
    Write-Host ""
    Write-Host $_.Exception.Message

    $global:LASTEXITCODE = 2
    return
}


if ($VMValidation.State -ne 'Off') {

    Write-Host "FAIL: VM must be powered off before Stage 4."
    Write-Host "Current State: $($VMValidation.State)"

    $global:LASTEXITCODE = 2
    return
}


Write-Host "PASS: VM remains powered off."


# ============================================================================
# 24. REVALIDATE INSTALLATION ISO
# ============================================================================

if (
    -not (
        Test-Path `
            -LiteralPath $ISOPath `
            -PathType Leaf
    )
) {

    Write-Host "FAIL: Installation ISO no longer exists."
    Write-Host "Path: $ISOPath"

    $global:LASTEXITCODE = 2
    return
}


try {

    $ISOFile = Get-Item `
        -LiteralPath $ISOPath `
        -ErrorAction Stop


    $ISOSizeGB = [math]::Round(
        $ISOFile.Length / 1GB,
        2
    )


    Write-Host "PASS: Installation ISO exists ($ISOSizeGB GB)."
}
catch {

    Write-Host "FAIL: Unable to inspect installation ISO."
    Write-Host ""
    Write-Host $_.Exception.Message

    $global:LASTEXITCODE = 2
    return
}


# ============================================================================
# 25. CONFIRM SCSI 0:1 IS AVAILABLE
# ============================================================================

try {

    $ExistingDVDLocation = @(
        Get-VMDvdDrive `
            -VMName $VMName `
            -ErrorAction Stop |
        Where-Object {
            $_.ControllerNumber -eq 0 -and
            $_.ControllerLocation -eq 1
        }
    )


    if ($ExistingDVDLocation.Count -gt 0) {

        Write-Host "FAIL: SCSI controller 0, location 1 is already occupied."
        Write-Host ""

        $ExistingDVDLocation |
            Select-Object `
                VMName,
                ControllerNumber,
                ControllerLocation,
                Path |
            Format-List

        $global:LASTEXITCODE = 2
        return
    }


    Write-Host "PASS: SCSI controller 0, location 1 is available."
}
catch {

    Write-Host "FAIL: Unable to inspect existing DVD drives."
    Write-Host ""
    Write-Host $_.Exception.Message

    $global:LASTEXITCODE = 2
    return
}


# ============================================================================
# 26. ATTACH INSTALLATION ISO
# ============================================================================

try {

    Add-VMDvdDrive `
        -VMName $VMName `
        -ControllerNumber 0 `
        -ControllerLocation 1 `
        -Path $ISOPath `
        -ErrorAction Stop


    Write-Host "PASS: Installation ISO attached."
}
catch {

    Write-Host "FAIL: Unable to attach installation ISO."
    Write-Host ""
    Write-Host $_.Exception.Message

    $global:LASTEXITCODE = 2
    return
}


# ============================================================================
# 27. VALIDATE DVD ATTACHMENT
# ============================================================================

try {

    $DVDValidation = Get-VMDvdDrive `
        -VMName $VMName `
        -ErrorAction Stop |
        Where-Object {
            $_.ControllerNumber -eq 0 -and
            $_.ControllerLocation -eq 1
        } |
        Select-Object -First 1


    if (-not $DVDValidation) {

        throw "Expected DVD drive was not found at SCSI 0:1."
    }


    Write-Host ""
    Write-Host "=== DVD DRIVE VALIDATION ==="
    Write-Host ""


    $DVDValidation |
        Select-Object `
            VMName,
            ControllerNumber,
            ControllerLocation,
            Path |
        Format-List


    $DVDValid = (
        $DVDValidation.ControllerNumber -eq 0 -and
        $DVDValidation.ControllerLocation -eq 1 -and
        $DVDValidation.Path -eq $ISOPath
    )


    if (-not $DVDValid) {

        Write-Host "FAIL: DVD drive does not match requested configuration."

        $global:LASTEXITCODE = 2
        return
    }


    Write-Host "PASS: DVD attachment matches requested configuration."
}
catch {

    Write-Host "FAIL: Unable to validate DVD attachment."
    Write-Host ""
    Write-Host $_.Exception.Message

    $global:LASTEXITCODE = 2
    return
}


# ============================================================================
# 28. CONFIGURE SECURE BOOT
# ============================================================================

try {

    Set-VMFirmware `
        -VMName $VMName `
        -EnableSecureBoot On `
        -SecureBootTemplate $SecureBootTemplate `
        -ErrorAction Stop


    Write-Host "PASS: Secure Boot configuration applied."
}
catch {

    Write-Host "FAIL: Unable to configure Secure Boot."
    Write-Host ""
    Write-Host $_.Exception.Message

    $global:LASTEXITCODE = 2
    return
}


# ============================================================================
# 29. SET DVD AS FIRST BOOT DEVICE
# ============================================================================

try {

    $BootDVD = Get-VMDvdDrive `
        -VMName $VMName `
        -ErrorAction Stop |
        Where-Object {
            $_.ControllerNumber -eq 0 -and
            $_.ControllerLocation -eq 1
        } |
        Select-Object -First 1


    if (-not $BootDVD) {

        throw "Unable to locate the DVD drive for boot-order configuration."
    }


    Set-VMFirmware `
        -VMName $VMName `
        -FirstBootDevice $BootDVD `
        -ErrorAction Stop


    Write-Host "PASS: DVD drive configured as first boot device."
}
catch {

    Write-Host "FAIL: Unable to configure firmware boot order."
    Write-Host ""
    Write-Host $_.Exception.Message

    $global:LASTEXITCODE = 2
    return
}


# ============================================================================
# 30. VALIDATE FIRMWARE
# ============================================================================

try {

    $FirmwareValidation = Get-VMFirmware `
        -VMName $VMName `
        -ErrorAction Stop


    Write-Host ""
    Write-Host "=== FIRMWARE VALIDATION ==="
    Write-Host ""

    Write-Host "Secure Boot          : $($FirmwareValidation.SecureBoot)"
    Write-Host "Secure Boot Template : $($FirmwareValidation.SecureBootTemplate)"
    Write-Host ""

    Write-Host "Boot Order:"
    Write-Host ""


    $BootIndex = 1

    foreach ($BootDevice in $FirmwareValidation.BootOrder) {

        $BootType = $BootDevice.BootType

        if (-not $BootType) {
            $BootType = $BootDevice.GetType().Name
        }


        $BootDescription = $BootDevice.Description

        if (-not $BootDescription) {
            $BootDescription = $BootDevice.ToString()
        }


        Write-Host "$BootIndex. $BootType - $BootDescription"

        $BootIndex++
    }


    $SecureBootValid = (
        $FirmwareValidation.SecureBoot -eq 'On'
    )


    $SecureBootTemplateValid = (
        $FirmwareValidation.SecureBootTemplate -eq $SecureBootTemplate
    )


    $FirstBootDevice =
        $FirmwareValidation.BootOrder |
        Select-Object -First 1


    $FirstBootIsDVD = $false


    if ($FirstBootDevice) {

        # Preferred method:
        # inspect the actual Hyper-V device associated with the first
        # firmware boot source.

        if ($FirstBootDevice.Device) {

            $FirstDevice = $FirstBootDevice.Device


            if (
                $FirstDevice.ControllerNumber -eq 0 -and
                $FirstDevice.ControllerLocation -eq 1 -and
                $FirstDevice.Path -eq $ISOPath
            ) {

                $FirstBootIsDVD = $true
            }
        }


        # Secondary identifier comparison if exposed by this Hyper-V build.

        if (
            -not $FirstBootIsDVD -and
            $FirstBootDevice.Device -and
            $FirstBootDevice.Device.Id -and
            $BootDVD.Id
        ) {

            if ($FirstBootDevice.Device.Id -eq $BootDVD.Id) {

                $FirstBootIsDVD = $true
            }
        }


        # Conservative fallback for Hyper-V builds that render the underlying
        # firmware boot source differently.

        if (-not $FirstBootIsDVD) {

            $FirstBootText =
                $FirstBootDevice |
                Out-String


            if ($FirstBootText -match 'DVD') {

                $FirstBootIsDVD = $true
            }
        }
    }


    if (-not $SecureBootValid) {

        Write-Host ""
        Write-Host "FAIL: Secure Boot is not enabled."

        $global:LASTEXITCODE = 2
        return
    }


    if (-not $SecureBootTemplateValid) {

        Write-Host ""
        Write-Host "FAIL: Secure Boot template does not match expected value."
        Write-Host "Expected : $SecureBootTemplate"
        Write-Host "Actual   : $($FirmwareValidation.SecureBootTemplate)"

        $global:LASTEXITCODE = 2
        return
    }


    if (-not $FirstBootIsDVD) {

        Write-Host ""
        Write-Host "FAIL: DVD could not be confirmed as the first boot device."
        Write-Host ""
        Write-Host "Review the firmware Boot Order above before continuing."

        $global:LASTEXITCODE = 2
        return
    }


    Write-Host ""
    Write-Host "PASS: Secure Boot is enabled."
    Write-Host "PASS: Secure Boot template is correct."
    Write-Host "PASS: DVD is the first boot device."
    Write-Host ""
    Write-Host "PASS: Firmware configuration matches requested state."
}
catch {

    Write-Host "FAIL: Unable to validate firmware configuration."
    Write-Host ""
    Write-Host $_.Exception.Message

    $global:LASTEXITCODE = 2
    return
}


# ============================================================================
# STAGE 5 - DESIRED STATE AND DRIFT VALIDATION
# ============================================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "Stage 5 - Desired-State Configuration and Drift Validation"
Write-Host "============================================================"
Write-Host ""


# ============================================================================
# 31. ENSURE CONFIG FOLDER EXISTS
# ============================================================================

try {

    if (
        -not (
            Test-Path `
                -LiteralPath $ConfigFolder `
                -PathType Container
        )
    ) {

        New-Item `
            -Path $ConfigFolder `
            -ItemType Directory `
            -Force `
            -ErrorAction Stop |
        Out-Null


        Write-Host "PASS: Desired-state config folder created."
    }
    else {

        Write-Host "PASS: Desired-state config folder already exists."
    }
}
catch {

    Write-Host "FAIL: Unable to create desired-state config folder."
    Write-Host ""
    Write-Host $_.Exception.Message

    $global:LASTEXITCODE = 2
    return
}


# ============================================================================
# 32. RECHECK CONFIG FILE COLLISION
# ============================================================================

# Stage 1 checked this before the build began.
#
# Check again immediately before writing to protect against an unexpected
# file appearing during the build.

if (Test-Path -LiteralPath $ConfigPath) {

    Write-Host "FAIL: Desired-state configuration file already exists."
    Write-Host ""
    Write-Host "Path: $ConfigPath"
    Write-Host ""
    Write-Host "The existing file will not be overwritten automatically."

    $global:LASTEXITCODE = 2
    return
}


Write-Host "PASS: Desired-state configuration filename remains available."


# ============================================================================
# 33. BUILD PSD1 FROM REQUESTED STATE
# ============================================================================

# CRITICAL DESIGN RULE:
#
# This data comes from the build request.
#
# It is NOT generated by reading the resulting VM and accepting whatever
# Hyper-V currently contains.
#
# Therefore:
#
#     Requested values = desired state
#     Live VM          = actual state
#
# Test-HyperVVMConfiguration.ps1 will compare the two independently.

$ConfigContent = @"
@{
    VMName                  = "$VMName"
    Generation              = $Generation
    ProcessorCount          = $ProcessorCount
    StartupMemoryGB         = $StartupMemoryGB
    DynamicMemoryEnabled    = `$$DynamicMemoryEnabled

    VHDXPath                = "$VHDXPath"
    VHDSizeGB               = $VHDSizeGB
    VHDType                 = "$VHDType"

    SecureBootEnabled       = `$$SecureBootEnabled
    SecureBootTemplate      = "$SecureBootTemplate"

    ExpectedSwitchName      = "$ExpectedSwitchName"
    ExpectedCheckpointCount = $ExpectedCheckpointCount
}
"@


# ============================================================================
# 34. WRITE DESIRED-STATE PSD1
# ============================================================================

try {

    $ConfigContent |
        Set-Content `
            -LiteralPath $ConfigPath `
            -Encoding UTF8 `
            -ErrorAction Stop


    Write-Host "PASS: Desired-state configuration written."
    Write-Host "Path: $ConfigPath"
}
catch {

    Write-Host "FAIL: Unable to write desired-state configuration."
    Write-Host ""
    Write-Host $_.Exception.Message

    $global:LASTEXITCODE = 2
    return
}


# ============================================================================
# 35. VALIDATE PSD1 SYNTAX
# ============================================================================

try {

    $ImportedConfig = Import-PowerShellDataFile `
        -Path $ConfigPath `
        -ErrorAction Stop


    Write-Host "PASS: Desired-state PSD1 imports successfully."
}
catch {

    Write-Host "FAIL: Desired-state PSD1 was written but cannot be imported."
    Write-Host ""
    Write-Host $_.Exception.Message
    Write-Host ""
    Write-Host "Review the generated file before continuing."

    $global:LASTEXITCODE = 2
    return
}


# ============================================================================
# 36. DISPLAY GENERATED DESIRED STATE
# ============================================================================

Write-Host ""
Write-Host "=== GENERATED DESIRED STATE ==="
Write-Host ""


$DisplaySwitchName = $ImportedConfig.ExpectedSwitchName

if ([string]::IsNullOrWhiteSpace($DisplaySwitchName)) {

    $DisplaySwitchName = "<None>"
}


[PSCustomObject]@{

    VMName              = $ImportedConfig.VMName
    Generation          = $ImportedConfig.Generation
    ProcessorCount      = $ImportedConfig.ProcessorCount
    StartupMemoryGB     = $ImportedConfig.StartupMemoryGB
    DynamicMemory       = $ImportedConfig.DynamicMemoryEnabled

    VHDXPath            = $ImportedConfig.VHDXPath
    VHDSizeGB           = $ImportedConfig.VHDSizeGB
    VHDType             = $ImportedConfig.VHDType

    SecureBoot          = $ImportedConfig.SecureBootEnabled
    SecureBootTemplate  = $ImportedConfig.SecureBootTemplate

    SwitchName          = $DisplaySwitchName

    ExpectedCheckpoints = $ImportedConfig.ExpectedCheckpointCount

} |
Format-List


# ============================================================================
# 37. LOCATE DRIFT VALIDATOR
# ============================================================================

# The validator is expected to reside beside this build script.

$ValidatorPath = Join-Path `
    -Path $PSScriptRoot `
    -ChildPath "Test-HyperVVMConfiguration.ps1"


if (
    -not (
        Test-Path `
            -LiteralPath $ValidatorPath `
            -PathType Leaf
    )
) {

    Write-Host "FAIL: Drift validation script was not found."
    Write-Host ""
    Write-Host "Expected path:"
    Write-Host $ValidatorPath
    Write-Host ""
    Write-Host "The VM and desired-state PSD1 have been created,"
    Write-Host "but automatic validation cannot continue."

    $global:LASTEXITCODE = 2
    return
}


Write-Host "PASS: Drift validation script located."
Write-Host "Path: $ValidatorPath"


# ============================================================================
# 38. RUN DRIFT VALIDATOR
# ============================================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "Running Expected-vs-Actual Configuration Validation"
Write-Host "============================================================"
Write-Host ""


try {

    # Initialise to a known failure value before invoking the validator.
    #
    # Test-HyperVVMConfiguration.ps1 is expected to set:
    #
    #     0 = configuration matches
    #     2 = configuration drift detected

    $global:LASTEXITCODE = 2


    & $ValidatorPath `
        -ConfigFile $ConfigPath


    $ValidatorExitCode = $global:LASTEXITCODE
}
catch {

    Write-Host ""
    Write-Host "FAIL: Unable to execute drift validator."
    Write-Host ""
    Write-Host $_.Exception.Message

    $global:LASTEXITCODE = 2
    return
}


# ============================================================================
# 39. EVALUATE DRIFT VALIDATOR
# ============================================================================

Write-Host ""


if ($ValidatorExitCode -eq 0) {

    Write-Host "PASS: Drift validator returned a successful result."
}
else {

    Write-Host "============================================================"
    Write-Host "RESULT: FAIL - CONFIGURATION VALIDATION FAILED"
    Write-Host "============================================================"
    Write-Host ""
    Write-Host "Validator Result : $ValidatorExitCode"
    Write-Host ""
    Write-Host "The VM was built and its desired-state file was created,"
    Write-Host "but the live VM does not fully match expected configuration."
    Write-Host ""
    Write-Host "Do NOT redefine the PSD1 from the live VM."
    Write-Host "Investigate the reported drift."

    $global:LASTEXITCODE = 2
    return
}


# ============================================================================
# FINAL RESULT
# ============================================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "RESULT: PASS - HYPER-V LAB VM BUILD COMPLETE"
Write-Host "============================================================"
Write-Host ""

Write-Host "VM Name          : $VMName"
Write-Host "Generation       : $Generation"
Write-Host "Processor Count  : $ProcessorCount"
Write-Host "Startup Memory   : $StartupMemoryGB GB"
Write-Host "Dynamic Memory   : $DynamicMemoryEnabled"

Write-Host ""

Write-Host "OS Disk          : $VHDXPath"
Write-Host "VHDX Type        : $VHDType"
Write-Host "VHDX Size        : $VHDSizeGB GB"
Write-Host "Disk Controller  : SCSI 0:0"

Write-Host ""

Write-Host "Installation ISO : $ISOPath"
Write-Host "DVD Controller   : SCSI 0:1"
Write-Host "Secure Boot      : Enabled"
Write-Host "Secure Template  : $SecureBootTemplate"
Write-Host "First Boot Device: DVD"

Write-Host ""

Write-Host "VM State         : Off"
Write-Host "Networking       : Deferred"
Write-Host "Expected Switch  : <None>"
Write-Host "Checkpoints      : 0 expected"

Write-Host ""

Write-Host "Desired State    : $ConfigPath"
Write-Host "Drift Validation : PASS"

Write-Host ""

Write-Host "The VM is boot-ready and matches the requested configuration."
Write-Host "The guest operating system has NOT been installed by this script."

Write-Host ""
Write-Host "============================================================"

$global:LASTEXITCODE = 0
