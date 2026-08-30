<#
.SYNOPSIS
    Performs a read-only Hyper-V storage audit.

.DESCRIPTION
    Audits Hyper-V virtual machine storage configuration and the underlying
    virtual disk files.

    The script can audit:

        - All VMs on the local Hyper-V host
        - One specific VM
        - The Hyper-V default virtual hard disk path
        - An explicitly supplied storage search path

    Checks include:

        HOST / STORAGE
        - Administrative privileges
        - Hyper-V availability
        - VMMS service
        - Hyper-V default VHD path
        - Search-path availability
        - Storage volume health
        - Free-space information

        VM ATTACHMENTS
        - VM hard-disk attachments
        - Missing referenced disk files
        - Controller locations
        - Duplicate/shared disk references

        VIRTUAL DISKS
        - VHD/VHDX format
        - Dynamic/fixed/differencing type
        - Maximum virtual size
        - Current physical file size
        - Parent paths
        - Differencing chains
        - Missing parents
        - Unreadable/broken VHD metadata

        CHECKPOINTS
        - VM checkpoints
        - AVHD/AVHDX differencing files
        - Active differencing chains
        - Potentially orphaned differencing files

        FILE INVENTORY
        - VHD
        - VHDX
        - AVHD
        - AVHDX
        - Potentially orphaned virtual disk files

        INSTALLATION MEDIA
        - Attached ISO files
        - Missing ISO references
        - Optional warning for attached ISO media

    RESULT MODEL

        PASS
            Expected healthy condition.

        INFO
            Inventory or contextual information that does not require action.

        WARNING
            Condition requiring operator review.

        FAIL
            Broken reference, missing disk, inaccessible chain or another
            condition that can prevent correct VM storage operation.

    EXIT CODES

        0 = Audit completed with no FAIL or WARNING findings
        1 = Audit completed with one or more WARNING findings
        2 = Audit completed with one or more FAIL findings

    IMPORTANT
        This script is read-only.

        It DOES NOT:
            - Delete VHD/VHDX/AVHDX files
            - Merge checkpoints
            - Remove checkpoints
            - Detach disks
            - Attach disks
            - Modify VM configuration
            - Change storage
            - Repair VHD chains

        A file reported as "potentially orphaned" must NEVER be deleted solely
        because this script reports it.

        Backup copies, manually retained disks, templates, imported disks and
        disks belonging to VMs not currently registered on this host can
        legitimately appear unattached.

.NOTES
    Run from an elevated PowerShell session.

.EXAMPLE
    Audit all VMs using the Hyper-V default virtual hard disk location:

        .\Get-HyperVStorageAudit.ps1

.EXAMPLE
    Audit a single VM:

        .\Get-HyperVStorageAudit.ps1 `
            -VMName "LAB-APP01"

.EXAMPLE
    Audit all VMs and explicitly scan a storage directory:

        .\Get-HyperVStorageAudit.ps1 `
            -SearchPath "D:\Hyper-V\Virtual Hard Disks"

.EXAMPLE
    Audit and save a text report:

        .\Get-HyperVStorageAudit.ps1 `
            -OutputDirectory "C:\HyperV-Baselines\StorageAudit"

.EXAMPLE
    Treat attached ISO media as a WARNING:

        .\Get-HyperVStorageAudit.ps1 `
            -WarnOnAttachedISO
#>


# ============================================================================
# PARAMETERS
# ============================================================================

[CmdletBinding()]
param (

    # Optional VM name.
    #
    # If omitted, all VMs registered on the local host are audited.
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$VMName,


    # Optional storage search root.
    #
    # If omitted, Hyper-V's configured VirtualHardDiskPath is used.
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$SearchPath,


    # Optional location for a human-readable transcript/report.
    #
    # If omitted, no report file is written.
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory,


    # Optional strict ISO mode.
    #
    # By default, a valid attached ISO is informational.
    #
    # If this switch is supplied, any valid attached ISO is reported
    # as WARNING so that installation media left mounted after deployment
    # is brought to the operator's attention.
    [Parameter(Mandatory = $false)]
    [switch]$WarnOnAttachedISO
)


# ============================================================================
# SCRIPT SETTINGS
# ============================================================================

$AuditDate = Get-Date

$Results = @()

$DiskInventory = @()

$AttachmentInventory = @()

$CheckpointInventory = @()

$ISOInventory = @()

$DiskChainInventory = @()


# ============================================================================
# HELPER FUNCTION - ADD AUDIT RESULT
# ============================================================================

function Add-AuditResult {

    param (

        [Parameter(Mandatory)]
        [string]$Category,

        [Parameter(Mandatory)]
        [string]$Check,

        [Parameter(Mandatory)]
        [ValidateSet(
            'PASS',
            'INFO',
            'WARNING',
            'FAIL'
        )]
        [string]$Status,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Details
    )


    $script:Results += [PSCustomObject]@{

        Category = $Category
        Check    = $Check
        Status   = $Status
        Details  = $Details
    }
}


# ============================================================================
# HELPER FUNCTION - NORMALISE PATH
# ============================================================================

function Get-NormalisedPath {

    param (

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Path
    )


    if ([string]::IsNullOrWhiteSpace($Path)) {

        return $null
    }


    try {

        return [System.IO.Path]::GetFullPath($Path).
            TrimEnd('\').
            ToLowerInvariant()
    }
    catch {

        return $Path.TrimEnd('\').ToLowerInvariant()
    }
}


# ============================================================================
# HELPER FUNCTION - GET RAW FILE SIZE IN GB
# ============================================================================

function Get-FileSizeGB {

    param (

        [Parameter(Mandatory)]
        [string]$Path
    )


    try {

        $Item = Get-Item `
            -LiteralPath $Path `
            -ErrorAction Stop


        return [math]::Round(
            $Item.Length / 1GB,
            2
        )
    }
    catch {

        return $null
    }
}


# ============================================================================
# HELPER FUNCTION - FORMAT PHYSICAL SIZE
# ============================================================================

function ConvertTo-FriendlySize {

    <#
    .SYNOPSIS
        Converts a byte value into an operator-friendly display string.

    .DESCRIPTION
        Small files are shown in KB or MB rather than rounding to 0 GB.

        Examples:

            4 MB
            512 MB
            15.88 GB
            1.2 TB
    #>

    param (

        [Parameter(Mandatory)]
        [ValidateRange(0, [long]::MaxValue)]
        [long]$Bytes
    )


    if ($Bytes -ge 1TB) {

        return "$(
            [math]::Round(
                $Bytes / 1TB,
                2
            )
        ) TB"
    }


    if ($Bytes -ge 1GB) {

        return "$(
            [math]::Round(
                $Bytes / 1GB,
                2
            )
        ) GB"
    }


    if ($Bytes -ge 1MB) {

        return "$(
            [math]::Round(
                $Bytes / 1MB,
                2
            )
        ) MB"
    }


    if ($Bytes -ge 1KB) {

        return "$(
            [math]::Round(
                $Bytes / 1KB,
                2
            )
        ) KB"
    }


    return "$Bytes Bytes"
}


# ============================================================================
# HELPER FUNCTION - RESOLVE VHD CHAIN
# ============================================================================

function Get-VHDChain {

    <#
    .SYNOPSIS
        Walks from a VHD/VHDX/AVHDX to its parent disk.

    .DESCRIPTION
        Returns one object per chain member.

        If a parent path is missing or Get-VHD cannot read a chain member,
        the failure is recorded rather than modifying anything.
    #>

    param (

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$VMName
    )


    $Chain = @()

    $CurrentPath = $Path

    $SeenPaths = @{}

    $Depth = 0


    while (
        -not [string]::IsNullOrWhiteSpace($CurrentPath)
    ) {

        $Depth++


        # Defensive limit against corrupt/circular chains.
        if ($Depth -gt 100) {

            Add-AuditResult `
                -Category "VHD Chain" `
                -Check "Chain depth" `
                -Status "FAIL" `
                -Details "Chain for '$Path' exceeded 100 entries."

            break
        }


        $NormalisedCurrent =
            Get-NormalisedPath `
                -Path $CurrentPath


        if ($SeenPaths.ContainsKey($NormalisedCurrent)) {

            Add-AuditResult `
                -Category "VHD Chain" `
                -Check "Circular reference" `
                -Status "FAIL" `
                -Details "Circular VHD chain detected at '$CurrentPath'."

            break
        }


        $SeenPaths[$NormalisedCurrent] = $true


        # --------------------------------------------------------------------
        # Missing current chain member
        # --------------------------------------------------------------------

        if (
            -not (
                Test-Path `
                    -LiteralPath $CurrentPath `
                    -PathType Leaf
            )
        ) {

            $Chain += [PSCustomObject]@{

                VMName      = $VMName
                Depth       = $Depth
                Path        = $CurrentPath
                Exists      = $false
                VhdFormat   = $null
                VhdType     = $null
                SizeGB      = $null
                FileSizeGB  = $null
                PhysicalSize = $null
                ParentPath  = $null
                Status      = "MISSING"
            }


            Add-AuditResult `
                -Category "VHD Chain" `
                -Check "Missing chain member" `
                -Status "FAIL" `
                -Details "VM '$VMName' references missing disk '$CurrentPath'."


            break
        }


        # --------------------------------------------------------------------
        # Read current chain member
        # --------------------------------------------------------------------

        try {

            $VHD = Get-VHD `
                -Path $CurrentPath `
                -ErrorAction Stop


            $PhysicalSize =
                ConvertTo-FriendlySize `
                    -Bytes $VHD.FileSize


            $Chain += [PSCustomObject]@{

                VMName      = $VMName
                Depth       = $Depth
                Path        = $CurrentPath
                Exists      = $true
                VhdFormat   = $VHD.VhdFormat
                VhdType     = $VHD.VhdType

                SizeGB      = [math]::Round(
                    $VHD.Size / 1GB,
                    2
                )

                FileSizeGB  = [math]::Round(
                    $VHD.FileSize / 1GB,
                    2
                )

                PhysicalSize = $PhysicalSize
                ParentPath   = $VHD.ParentPath
                Status       = "OK"
            }


            # Base disk reached.
            if (
                [string]::IsNullOrWhiteSpace(
                    $VHD.ParentPath
                )
            ) {

                break
            }


            # ----------------------------------------------------------------
            # Missing parent
            # ----------------------------------------------------------------

            if (
                -not (
                    Test-Path `
                        -LiteralPath $VHD.ParentPath `
                        -PathType Leaf
                )
            ) {

                Add-AuditResult `
                    -Category "VHD Chain" `
                    -Check "Missing parent disk" `
                    -Status "FAIL" `
                    -Details "Disk '$CurrentPath' references missing parent '$($VHD.ParentPath)'."


                $Chain += [PSCustomObject]@{

                    VMName       = $VMName
                    Depth        = ($Depth + 1)
                    Path         = $VHD.ParentPath
                    Exists       = $false
                    VhdFormat    = $null
                    VhdType      = $null
                    SizeGB       = $null
                    FileSizeGB   = $null
                    PhysicalSize = $null
                    ParentPath   = $null
                    Status       = "MISSING PARENT"
                }


                break
            }


            $CurrentPath = $VHD.ParentPath
        }
        catch {

            $FriendlySize = $null

            try {

                $CurrentItem = Get-Item `
                    -LiteralPath $CurrentPath `
                    -ErrorAction Stop


                $FriendlySize =
                    ConvertTo-FriendlySize `
                        -Bytes $CurrentItem.Length
            }
            catch {
            }


            Add-AuditResult `
                -Category "VHD Chain" `
                -Check "Unreadable VHD metadata" `
                -Status "FAIL" `
                -Details "Unable to read '$CurrentPath': $($_.Exception.Message)"


            $Chain += [PSCustomObject]@{

                VMName       = $VMName
                Depth        = $Depth
                Path         = $CurrentPath
                Exists       = $true
                VhdFormat    = $null
                VhdType      = $null
                SizeGB       = $null
                FileSizeGB   = Get-FileSizeGB -Path $CurrentPath
                PhysicalSize = $FriendlySize
                ParentPath   = $null
                Status       = "UNREADABLE"
            }


            break
        }
    }


    return $Chain
}


# ============================================================================
# REPORT / TRANSCRIPT SETUP
# ============================================================================

$TranscriptStarted = $false

$ReportPath = $null


if ($OutputDirectory) {

    try {

        if (
            -not (
                Test-Path `
                    -LiteralPath $OutputDirectory `
                    -PathType Container
            )
        ) {

            New-Item `
                -Path $OutputDirectory `
                -ItemType Directory `
                -Force `
                -ErrorAction Stop |
            Out-Null
        }


        $SafeTargetName = if ($VMName) {
            $VMName
        }
        else {
            "ALL-VMs"
        }


        $Timestamp =
            Get-Date -Format "yyyyMMdd-HHmmss"


        $ReportPath = Join-Path `
            -Path $OutputDirectory `
            -ChildPath "$env:COMPUTERNAME-$SafeTargetName-StorageAudit-$Timestamp.txt"


        Start-Transcript `
            -Path $ReportPath `
            -ErrorAction Stop |
        Out-Null


        $TranscriptStarted = $true
    }
    catch {

        Write-Warning "Unable to start report transcript: $($_.Exception.Message)"
    }
}


# ============================================================================
# HEADER
# ============================================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "Hyper-V Storage Audit"
Write-Host "============================================================"
Write-Host ""

Write-Host "Host                : $env:COMPUTERNAME"
Write-Host "Scope               : $(if ($VMName) { $VMName } else { 'All VMs' })"
Write-Host "Date                : $($AuditDate.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "Read Only           : True"
Write-Host "Warn On Attached ISO: $($WarnOnAttachedISO.IsPresent)"

if ($ReportPath) {

    Write-Host "Report              : $ReportPath"
}

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

    Add-AuditResult `
        -Category "Host" `
        -Check "Administrative privileges" `
        -Status "PASS" `
        -Details "PowerShell is running elevated."
}
else {

    Add-AuditResult `
        -Category "Host" `
        -Check "Administrative privileges" `
        -Status "WARNING" `
        -Details "PowerShell is not elevated. Some Hyper-V/storage information may be unavailable."
}


# ============================================================================
# 2. HYPER-V AVAILABILITY
# ============================================================================

try {

    $VMHost = Get-VMHost `
        -ErrorAction Stop


    Add-AuditResult `
        -Category "Host" `
        -Check "Hyper-V availability" `
        -Status "PASS" `
        -Details "Hyper-V host successfully queried."
}
catch {

    Add-AuditResult `
        -Category "Host" `
        -Check "Hyper-V availability" `
        -Status "FAIL" `
        -Details $_.Exception.Message


    $Results |
        Format-Table `
            Category,
            Check,
            Status,
            Details `
            -AutoSize `
            -Wrap


    if ($TranscriptStarted) {
        Stop-Transcript | Out-Null
    }


    $global:LASTEXITCODE = 2
    return
}


# ============================================================================
# 3. VMMS SERVICE
# ============================================================================

try {

    $VMMS = Get-Service `
        -Name vmms `
        -ErrorAction Stop


    if ($VMMS.Status -eq 'Running') {

        Add-AuditResult `
            -Category "Host" `
            -Check "VMMS service" `
            -Status "PASS" `
            -Details "VMMS is running."
    }
    else {

        Add-AuditResult `
            -Category "Host" `
            -Check "VMMS service" `
            -Status "WARNING" `
            -Details "VMMS state is $($VMMS.Status)."
    }
}
catch {

    Add-AuditResult `
        -Category "Host" `
        -Check "VMMS service" `
        -Status "WARNING" `
        -Details "Unable to query VMMS."
}


# ============================================================================
# 4. DETERMINE VM SCOPE
# ============================================================================

try {

    if ($VMName) {

        $VMs = @(
            Get-VM `
                -Name $VMName `
                -ErrorAction Stop
        )
    }
    else {

        $VMs = @(
            Get-VM `
                -ErrorAction Stop
        )
    }


    Add-AuditResult `
        -Category "Scope" `
        -Check "VM scope" `
        -Status "INFO" `
        -Details "$($VMs.Count) VM(s) included in audit."
}
catch {

    Add-AuditResult `
        -Category "Scope" `
        -Check "VM scope" `
        -Status "FAIL" `
        -Details $_.Exception.Message


    $VMs = @()
}


# ============================================================================
# 5. DETERMINE STORAGE SEARCH PATH
# ============================================================================

if (-not $SearchPath) {

    $SearchPath = $VMHost.VirtualHardDiskPath
}


if (
    Test-Path `
        -LiteralPath $SearchPath `
        -PathType Container
) {

    Add-AuditResult `
        -Category "Storage" `
        -Check "Search path" `
        -Status "PASS" `
        -Details "'$SearchPath' exists."
}
else {

    Add-AuditResult `
        -Category "Storage" `
        -Check "Search path" `
        -Status "FAIL" `
        -Details "'$SearchPath' does not exist."
}


Add-AuditResult `
    -Category "Storage" `
    -Check "Hyper-V default VHD path" `
    -Status "INFO" `
    -Details $VMHost.VirtualHardDiskPath


# ============================================================================
# 6. STORAGE VOLUME HEALTH
# ============================================================================

try {

    $SearchDrive = Split-Path `
        -Path $SearchPath `
        -Qualifier


    if ($SearchDrive) {

        $DriveLetter =
            $SearchDrive.TrimEnd(':').TrimEnd('\')


        $Volume = Get-Volume `
            -DriveLetter $DriveLetter `
            -ErrorAction Stop


        $FreeGB =
            [math]::Round(
                $Volume.SizeRemaining / 1GB,
                2
            )


        $TotalGB =
            [math]::Round(
                $Volume.Size / 1GB,
                2
            )


        $FreePercent = if ($Volume.Size -gt 0) {

            [math]::Round(
                (
                    $Volume.SizeRemaining /
                    $Volume.Size
                ) * 100,
                1
            )
        }
        else {

            0
        }


        $VolumeDetails =
            "$DriveLetter`: $($Volume.FileSystem), " +
            "Health=$($Volume.HealthStatus), " +
            "Free=$FreeGB GB / $TotalGB GB ($FreePercent%)"


        if ($Volume.HealthStatus -eq 'Healthy') {

            Add-AuditResult `
                -Category "Storage" `
                -Check "Storage volume health" `
                -Status "PASS" `
                -Details $VolumeDetails
        }
        else {

            Add-AuditResult `
                -Category "Storage" `
                -Check "Storage volume health" `
                -Status "WARNING" `
                -Details $VolumeDetails
        }


        if ($FreePercent -lt 10) {

            Add-AuditResult `
                -Category "Storage" `
                -Check "Free space" `
                -Status "WARNING" `
                -Details "Only $FreePercent% free space remains on $DriveLetter`:."
        }
        else {

            Add-AuditResult `
                -Category "Storage" `
                -Check "Free space" `
                -Status "PASS" `
                -Details "$FreePercent% free space remains on $DriveLetter`:."
        }
    }
}
catch {

    Add-AuditResult `
        -Category "Storage" `
        -Check "Storage volume" `
        -Status "WARNING" `
        -Details "Unable to obtain volume information: $($_.Exception.Message)"
}


# ============================================================================
# 7. VM HARD-DISK ATTACHMENTS
# ============================================================================

foreach ($VM in $VMs) {

    try {

        $VMDisks = @(
            Get-VMHardDiskDrive `
                -VMName $VM.Name `
                -ErrorAction Stop
        )


        if ($VMDisks.Count -eq 0) {

            Add-AuditResult `
                -Category "VM Attachment" `
                -Check "$($VM.Name) hard disks" `
                -Status "WARNING" `
                -Details "VM has no virtual hard disks attached."


            continue
        }


        foreach ($Disk in $VMDisks) {

            $Exists =
                Test-Path `
                    -LiteralPath $Disk.Path `
                    -PathType Leaf


            $AttachmentInventory += [PSCustomObject]@{

                VMName             = $VM.Name
                VMState            = $VM.State
                ControllerType     = $Disk.ControllerType
                ControllerNumber   = $Disk.ControllerNumber
                ControllerLocation = $Disk.ControllerLocation
                Path               = $Disk.Path
                Exists             = $Exists
            }


            if ($Exists) {

                Add-AuditResult `
                    -Category "VM Attachment" `
                    -Check "$($VM.Name) disk reference" `
                    -Status "PASS" `
                    -Details "$($Disk.Path) exists."
            }
            else {

                Add-AuditResult `
                    -Category "VM Attachment" `
                    -Check "$($VM.Name) disk reference" `
                    -Status "FAIL" `
                    -Details "Referenced disk is missing: '$($Disk.Path)'."
            }


            if ($Disk.Path) {

                $Chain = @(
                    Get-VHDChain `
                        -Path $Disk.Path `
                        -VMName $VM.Name
                )


                $DiskChainInventory += $Chain
            }
        }
    }
    catch {

        Add-AuditResult `
            -Category "VM Attachment" `
            -Check "$($VM.Name) disk query" `
            -Status "FAIL" `
            -Details $_.Exception.Message
    }
}


# ============================================================================
# 8. DISPLAY VM ATTACHMENTS
# ============================================================================

Write-Host ""
Write-Host "=== VM STORAGE ATTACHMENTS ==="
Write-Host ""


if ($AttachmentInventory.Count -gt 0) {

    $AttachmentInventory |
        Sort-Object `
            VMName,
            ControllerNumber,
            ControllerLocation |
        Format-Table `
            VMName,
            VMState,
            ControllerType,
            ControllerNumber,
            ControllerLocation,
            Exists,
            Path `
            -AutoSize `
            -Wrap
}
else {

    Write-Host "No VM hard-disk attachments found."
}


# ============================================================================
# 9. DUPLICATE / SHARED DISK REFERENCES
# ============================================================================

$DuplicateAttachments =
    $AttachmentInventory |
    Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.Path)
    } |
    Group-Object {
        Get-NormalisedPath -Path $_.Path
    } |
    Where-Object {
        $_.Count -gt 1
    }


foreach ($Duplicate in $DuplicateAttachments) {

    $VMList =
        (
            $Duplicate.Group.VMName |
            Sort-Object -Unique
        ) -join ", "


    Add-AuditResult `
        -Category "VM Attachment" `
        -Check "Shared disk reference" `
        -Status "WARNING" `
        -Details "Disk '$($Duplicate.Group[0].Path)' is referenced $($Duplicate.Count) times. VMs: $VMList."
}


# ============================================================================
# 10. DISPLAY VHD CHAIN
# ============================================================================

Write-Host ""
Write-Host "=== VHD / VHDX CHAIN AUDIT ==="
Write-Host ""


if ($DiskChainInventory.Count -gt 0) {

    $DiskChainInventory |
        Sort-Object `
            VMName,
            Depth |
        Format-Table `
            VMName,
            Depth,
            Exists,
            VhdFormat,
            VhdType,
            SizeGB,
            PhysicalSize,
            Status,
            Path `
            -AutoSize `
            -Wrap
}
else {

    Write-Host "No VHD chain information available."
}


# ============================================================================
# 11. CHECKPOINT INVENTORY
# ============================================================================

foreach ($VM in $VMs) {

    try {

        $Snapshots = @(
            Get-VMSnapshot `
                -VMName $VM.Name `
                -ErrorAction Stop
        )


        if ($Snapshots.Count -eq 0) {

            Add-AuditResult `
                -Category "Checkpoint" `
                -Check "$($VM.Name) checkpoints" `
                -Status "PASS" `
                -Details "No checkpoints found."
        }
        else {

            Add-AuditResult `
                -Category "Checkpoint" `
                -Check "$($VM.Name) checkpoints" `
                -Status "WARNING" `
                -Details "$($Snapshots.Count) checkpoint(s) found."


            foreach ($Snapshot in $Snapshots) {

                $CheckpointInventory += [PSCustomObject]@{

                    VMName       = $VM.Name
                    Name         = $Snapshot.Name
                    SnapshotType = $Snapshot.SnapshotType
                    CreationTime = $Snapshot.CreationTime
                }
            }
        }
    }
    catch {

        Add-AuditResult `
            -Category "Checkpoint" `
            -Check "$($VM.Name) checkpoint query" `
            -Status "WARNING" `
            -Details $_.Exception.Message
    }
}


Write-Host ""
Write-Host "=== CHECKPOINT INVENTORY ==="
Write-Host ""


if ($CheckpointInventory.Count -gt 0) {

    $CheckpointInventory |
        Sort-Object `
            VMName,
            CreationTime |
        Format-Table `
            VMName,
            Name,
            SnapshotType,
            CreationTime `
            -AutoSize `
            -Wrap
}
else {

    Write-Host "No checkpoints found."
}


# ============================================================================
# 12. DVD / ISO ATTACHMENTS
# ============================================================================

foreach ($VM in $VMs) {

    try {

        $DVDDrives = @(
            Get-VMDvdDrive `
                -VMName $VM.Name `
                -ErrorAction Stop
        )


        foreach ($DVD in $DVDDrives) {

            # ----------------------------------------------------------------
            # Empty DVD drive
            # ----------------------------------------------------------------

            if (
                [string]::IsNullOrWhiteSpace(
                    $DVD.Path
                )
            ) {

                $ISOInventory += [PSCustomObject]@{

                    VMName             = $VM.Name
                    ControllerNumber   = $DVD.ControllerNumber
                    ControllerLocation = $DVD.ControllerLocation
                    Path               = $null
                    Exists             = $null
                    AuditStatus        = "INFO"
                }


                Add-AuditResult `
                    -Category "ISO" `
                    -Check "$($VM.Name) DVD drive" `
                    -Status "INFO" `
                    -Details "DVD drive exists with no media attached."


                continue
            }


            # ----------------------------------------------------------------
            # Attached ISO
            # ----------------------------------------------------------------

            $ISOExists =
                Test-Path `
                    -LiteralPath $DVD.Path `
                    -PathType Leaf


            $ISOStatus = "INFO"


            if ($ISOExists -and $WarnOnAttachedISO.IsPresent) {

                $ISOStatus = "WARNING"
            }


            if (-not $ISOExists) {

                $ISOStatus = "WARNING"
            }


            $ISOInventory += [PSCustomObject]@{

                VMName             = $VM.Name
                ControllerNumber   = $DVD.ControllerNumber
                ControllerLocation = $DVD.ControllerLocation
                Path               = $DVD.Path
                Exists             = $ISOExists
                AuditStatus        = $ISOStatus
            }


            if (-not $ISOExists) {

                Add-AuditResult `
                    -Category "ISO" `
                    -Check "$($VM.Name) ISO reference" `
                    -Status "WARNING" `
                    -Details "Attached ISO path does not exist: '$($DVD.Path)'."
            }
            elseif ($WarnOnAttachedISO.IsPresent) {

                Add-AuditResult `
                    -Category "ISO" `
                    -Check "$($VM.Name) attached ISO" `
                    -Status "WARNING" `
                    -Details "ISO remains attached: '$($DVD.Path)'. Review whether installation media is still required."
            }
            else {

                Add-AuditResult `
                    -Category "ISO" `
                    -Check "$($VM.Name) ISO reference" `
                    -Status "INFO" `
                    -Details "ISO attached: '$($DVD.Path)'."
            }
        }
    }
    catch {

        Add-AuditResult `
            -Category "ISO" `
            -Check "$($VM.Name) DVD query" `
            -Status "WARNING" `
            -Details $_.Exception.Message
    }
}


Write-Host ""
Write-Host "=== DVD / ISO INVENTORY ==="
Write-Host ""


if ($ISOInventory.Count -gt 0) {

    $ISOInventory |
        Format-Table `
            VMName,
            ControllerNumber,
            ControllerLocation,
            Exists,
            AuditStatus,
            Path `
            -AutoSize `
            -Wrap
}
else {

    Write-Host "No DVD drives or ISO attachments found."
}


# ============================================================================
# 13. FILE-SYSTEM VIRTUAL DISK INVENTORY
# ============================================================================

Write-Host ""
Write-Host "=== DISK FILE INVENTORY ==="
Write-Host ""


if (
    Test-Path `
        -LiteralPath $SearchPath `
        -PathType Container
) {

    try {

        $VirtualDiskFiles = @(
            Get-ChildItem `
                -LiteralPath $SearchPath `
                -File `
                -Recurse `
                -ErrorAction Stop |
            Where-Object {
                $_.Extension -in @(
                    '.vhd',
                    '.vhdx',
                    '.avhd',
                    '.avhdx'
                )
            }
        )


        foreach ($File in $VirtualDiskFiles) {

            $NormalisedFile =
                Get-NormalisedPath `
                    -Path $File.FullName


            $ChainMatches = @(
                $DiskChainInventory |
                Where-Object {
                    (
                        Get-NormalisedPath `
                            -Path $_.Path
                    ) -eq $NormalisedFile
                }
            )


            $DirectMatches = @(
                $AttachmentInventory |
                Where-Object {
                    (
                        Get-NormalisedPath `
                            -Path $_.Path
                    ) -eq $NormalisedFile
                }
            )


            $InUse =
                (
                    $ChainMatches.Count -gt 0 -or
                    $DirectMatches.Count -gt 0
                )


            $FileType =
                $File.Extension.TrimStart('.').ToUpperInvariant()


            $DiskRecord = [ordered]@{

                FileName      = $File.Name
                Extension     = $FileType
                VhdType       = $null
                VirtualGB     = $null

                FileSizeGB    = [math]::Round(
                    $File.Length / 1GB,
                    2
                )

                PhysicalSize  = ConvertTo-FriendlySize `
                    -Bytes $File.Length

                InKnownChain  = $InUse
                ParentPath    = $null
                Path          = $File.FullName
            }


            try {

                $DiskMeta = Get-VHD `
                    -Path $File.FullName `
                    -ErrorAction Stop


                $DiskRecord.VhdType =
                    $DiskMeta.VhdType


                $DiskRecord.VirtualGB =
                    [math]::Round(
                        $DiskMeta.Size / 1GB,
                        2
                    )


                $DiskRecord.ParentPath =
                    $DiskMeta.ParentPath
            }
            catch {

                Add-AuditResult `
                    -Category "Disk File" `
                    -Check "Unreadable virtual disk" `
                    -Status "WARNING" `
                    -Details "Unable to read VHD metadata for '$($File.FullName)': $($_.Exception.Message)"
            }


            $DiskInventory +=
                [PSCustomObject]$DiskRecord
        }


        $DiskInventory |
            Sort-Object Path |
            Format-Table `
                FileName,
                Extension,
                VhdType,
                VirtualGB,
                PhysicalSize,
                InKnownChain,
                Path `
                -AutoSize `
                -Wrap
    }
    catch {

        Add-AuditResult `
            -Category "Disk File" `
            -Check "Disk file inventory" `
            -Status "WARNING" `
            -Details "Unable to scan '$SearchPath': $($_.Exception.Message)"
    }
}
else {

    Write-Host "Search path unavailable. File inventory skipped."
}


# ============================================================================
# 14. POTENTIALLY ORPHANED DISKS
# ============================================================================

$PotentialOrphans = @(
    $DiskInventory |
    Where-Object {
        $_.InKnownChain -eq $false
    }
)


foreach ($Orphan in $PotentialOrphans) {

    if (
        $Orphan.Extension -in @(
            'AVHD',
            'AVHDX'
        )
    ) {

        Add-AuditResult `
            -Category "Orphan" `
            -Check "Unreferenced differencing disk" `
            -Status "WARNING" `
            -Details "Potentially orphaned differencing disk: '$($Orphan.Path)'. DO NOT delete without validating its chain/history."
    }
    else {

        Add-AuditResult `
            -Category "Orphan" `
            -Check "Unreferenced virtual disk" `
            -Status "WARNING" `
            -Details "Potentially orphaned disk: '$($Orphan.Path)'. Confirm ownership before cleanup."
    }
}


Write-Host ""
Write-Host "=== POTENTIALLY ORPHANED DISKS ==="
Write-Host ""


if ($PotentialOrphans.Count -gt 0) {

    $PotentialOrphans |
        Format-Table `
            FileName,
            Extension,
            VhdType,
            VirtualGB,
            PhysicalSize,
            Path `
            -AutoSize `
            -Wrap
}
else {

    Write-Host "No potentially orphaned virtual disks found in the search path."
}


# ============================================================================
# 15. AVHD / AVHDX AUDIT
# ============================================================================

$DifferencingFiles = @(
    $DiskInventory |
    Where-Object {
        $_.Extension -in @(
            'AVHD',
            'AVHDX'
        )
    }
)


if ($DifferencingFiles.Count -eq 0) {

    Add-AuditResult `
        -Category "Differencing Disk" `
        -Check "AVHD/AVHDX files" `
        -Status "PASS" `
        -Details "No AVHD/AVHDX files found under '$SearchPath'."
}
else {

    $KnownDiffFiles = @(
        $DifferencingFiles |
        Where-Object {
            $_.InKnownChain
        }
    )


    $UnknownDiffFiles = @(
        $DifferencingFiles |
        Where-Object {
            -not $_.InKnownChain
        }
    )


    if ($KnownDiffFiles.Count -gt 0) {

        Add-AuditResult `
            -Category "Differencing Disk" `
            -Check "Known AVHD/AVHDX files" `
            -Status "INFO" `
            -Details "$($KnownDiffFiles.Count) differencing disk(s) participate in known VM chains."
    }


    if ($UnknownDiffFiles.Count -gt 0) {

        Add-AuditResult `
            -Category "Differencing Disk" `
            -Check "Unknown AVHD/AVHDX files" `
            -Status "WARNING" `
            -Details "$($UnknownDiffFiles.Count) AVHD/AVHDX file(s) are not part of a currently known registered-VM chain."
    }
}


# ============================================================================
# 16. STORAGE TOTALS
# ============================================================================

$TotalDiskFiles =
    $DiskInventory.Count


$TotalPhysicalBytes = 0


foreach ($DiskFile in $DiskInventory) {

    try {

        $Item = Get-Item `
            -LiteralPath $DiskFile.Path `
            -ErrorAction Stop


        $TotalPhysicalBytes += $Item.Length
    }
    catch {
    }
}


$TotalPhysicalGB =
    [math]::Round(
        $TotalPhysicalBytes / 1GB,
        2
    )


$TotalPhysicalFriendly =
    ConvertTo-FriendlySize `
        -Bytes $TotalPhysicalBytes


$AttachedDiskCount =
    $AttachmentInventory.Count


$MissingAttachmentCount = @(
    $AttachmentInventory |
    Where-Object {
        $_.Exists -eq $false
    }
).Count


$CheckpointCount =
    $CheckpointInventory.Count


$AVHDXCount =
    $DifferencingFiles.Count


$OrphanCount =
    $PotentialOrphans.Count


$AttachedISOCount = @(
    $ISOInventory |
    Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.Path)
    }
).Count


$MissingISOCount = @(
    $ISOInventory |
    Where-Object {
        $_.Exists -eq $false
    }
).Count


# ============================================================================
# 17. AUDIT SUMMARY
# ============================================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "AUDIT SUMMARY"
Write-Host "============================================================"
Write-Host ""

Write-Host "VMs Audited                  : $($VMs.Count)"
Write-Host "VM Disk Attachments          : $AttachedDiskCount"
Write-Host "Missing Referenced Disks     : $MissingAttachmentCount"
Write-Host "Virtual Disk Files Scanned   : $TotalDiskFiles"
Write-Host "Physical Disk Consumption    : $TotalPhysicalFriendly"
Write-Host "Physical Disk Consumption GB : $TotalPhysicalGB"
Write-Host "Potential Orphan Disks       : $OrphanCount"
Write-Host "AVHD / AVHDX Files           : $AVHDXCount"
Write-Host "Checkpoints                  : $CheckpointCount"
Write-Host "DVD Entries                  : $($ISOInventory.Count)"
Write-Host "Attached ISO Files           : $AttachedISOCount"
Write-Host "Missing ISO References       : $MissingISOCount"
Write-Host ""


# ============================================================================
# 18. FINDING TABLE
# ============================================================================

Write-Host "=== AUDIT FINDINGS ==="
Write-Host ""


$Results |
    Format-Table `
        Category,
        Check,
        Status,
        Details `
        -AutoSize `
        -Wrap


# ============================================================================
# 19. RESULT COUNTS
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
# 20. FINAL AUDIT DECISION
# ============================================================================

if ($FailCount -gt 0) {

    Write-Host "============================================================"
    Write-Host "RESULT: FAIL - STORAGE INCONSISTENCY DETECTED"
    Write-Host "============================================================"
    Write-Host ""
    Write-Host "One or more broken or missing storage references were found."
    Write-Host "Review FAIL findings before making changes."

    $global:LASTEXITCODE = 2
}
elseif ($WarningCount -gt 0) {

    Write-Host "============================================================"
    Write-Host "RESULT: REVIEW - STORAGE FINDINGS REQUIRE REVIEW"
    Write-Host "============================================================"
    Write-Host ""
    Write-Host "No hard storage failure was detected,"
    Write-Host "but one or more conditions require operator review."
    Write-Host ""
    Write-Host "Potentially orphaned files must not be deleted solely"
    Write-Host "because they appear in this report."

    $global:LASTEXITCODE = 1
}
else {

    Write-Host "============================================================"
    Write-Host "RESULT: PASS - STORAGE AUDIT CLEAN"
    Write-Host "============================================================"
    Write-Host ""
    Write-Host "No storage failures or review conditions were detected."

    $global:LASTEXITCODE = 0
}


# ============================================================================
# 21. REPORT LOCATION
# ============================================================================

if ($ReportPath) {

    Write-Host ""
    Write-Host "Report:"
    Write-Host $ReportPath
}


# ============================================================================
# 22. CLOSE TRANSCRIPT
# ============================================================================

if ($TranscriptStarted) {

    Stop-Transcript |
        Out-Null
}
