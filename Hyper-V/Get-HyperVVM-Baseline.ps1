[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$VMName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$BaselineFolder = "C:\HyperV-Baselines"
)

# ---------------------------------------------------------------------------
# Create baseline folder if needed
# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $BaselineFolder)) {

    New-Item `
        -Path $BaselineFolder `
        -ItemType Directory `
        -Force |
    Out-Null
}

# ---------------------------------------------------------------------------
# Build transcript filename
# ---------------------------------------------------------------------------

$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

$TranscriptPath = Join-Path `
    -Path $BaselineFolder `
    -ChildPath "$VMName-$Timestamp.txt"

# ---------------------------------------------------------------------------
# Confirm VM exists before starting transcript
# ---------------------------------------------------------------------------

try {

    $VM = Get-VM `
        -Name $VMName `
        -ErrorAction Stop
}
catch {

    Write-Error "Unable to find VM '$VMName'."
    return
}

# ---------------------------------------------------------------------------
# Start evidence capture
# ---------------------------------------------------------------------------

Start-Transcript `
    -Path $TranscriptPath `
    -Force

try {

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "Hyper-V VM Baseline Capture"
    Write-Host "============================================================"
    Write-Host ""
    Write-Host "Host          : $env:COMPUTERNAME"
    Write-Host "VM Name       : $VMName"
    Write-Host "Capture Time  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host "Output File   : $TranscriptPath"
    Write-Host ""

    # -----------------------------------------------------------------------
    # VM CONFIGURATION
    # -----------------------------------------------------------------------

    Write-Host "=== VM CONFIGURATION ==="

    $VM |
        Select-Object `
            Name,
            State,
            Status,
            Generation,
            ProcessorCount,
            MemoryStartup,
            MemoryAssigned,
            DynamicMemoryEnabled,
            Uptime

    # -----------------------------------------------------------------------
    # VIRTUAL DISK ATTACHMENTS
    # -----------------------------------------------------------------------

    Write-Host ""
    Write-Host "=== VIRTUAL DISK ATTACHMENTS ==="

    $VMDisks = @(
        Get-VMHardDiskDrive `
            -VMName $VMName `
            -ErrorAction Stop
    )

    if ($VMDisks.Count -gt 0) {

        $VMDisks |
            Select-Object `
                ControllerType,
                ControllerNumber,
                ControllerLocation,
                Path
    }
    else {

        Write-Host "No virtual hard disks are attached."
    }

    # -----------------------------------------------------------------------
    # VHD PROPERTIES
    # -----------------------------------------------------------------------

    Write-Host ""
    Write-Host "=== VHD PROPERTIES ==="

    foreach ($Disk in $VMDisks) {

        if (
            $Disk.Path -and
            (Test-Path -LiteralPath $Disk.Path)
        ) {

            Get-VHD `
                -Path $Disk.Path `
                -ErrorAction Stop |
            Select-Object `
                Path,
                VhdFormat,
                VhdType,
                Size,
                FileSize
        }
        else {

            Write-Warning "Attached disk path does not exist: $($Disk.Path)"
        }
    }

    # -----------------------------------------------------------------------
    # NETWORK ADAPTERS
    # -----------------------------------------------------------------------

    Write-Host ""
    Write-Host "=== NETWORK ADAPTERS ==="

    $VMNetworkAdapters = @(
        Get-VMNetworkAdapter `
            -VMName $VMName `
            -ErrorAction Stop
    )

    if ($VMNetworkAdapters.Count -gt 0) {

        $VMNetworkAdapters |
            Select-Object `
                Name,
                SwitchName,
                Status,
                MacAddress,
                IPAddresses
    }
    else {

        Write-Host "No VM network adapters found."
    }

    # -----------------------------------------------------------------------
    # FIRMWARE
    # -----------------------------------------------------------------------

    Write-Host ""
    Write-Host "=== FIRMWARE ==="

    if ($VM.Generation -eq 2) {

        Get-VMFirmware `
            -VMName $VMName `
            -ErrorAction Stop |
        Select-Object `
            SecureBoot,
            SecureBootTemplate
    }
    else {

        Write-Host "Generation 1 VM - UEFI firmware settings do not apply."
    }

    # -----------------------------------------------------------------------
    # DVD DRIVES
    # -----------------------------------------------------------------------

    Write-Host ""
    Write-Host "=== DVD DRIVES ==="

    $DVDDrives = @(
        Get-VMDvdDrive `
            -VMName $VMName `
            -ErrorAction Stop
    )

    if ($DVDDrives.Count -gt 0) {

        $DVDDrives |
            Select-Object `
                ControllerType,
                ControllerNumber,
                ControllerLocation,
                DvdMediaType,
                Path
    }
    else {

        Write-Host "No virtual DVD drives found."
    }

    # -----------------------------------------------------------------------
    # CHECKPOINTS
    # -----------------------------------------------------------------------

    Write-Host ""
    Write-Host "=== CHECKPOINTS ==="

    $Snapshots = @(
        Get-VMSnapshot `
            -VMName $VMName `
            -ErrorAction SilentlyContinue
    )

    if ($Snapshots.Count -eq 0) {

        Write-Host "No checkpoints found."
    }
    else {

        $Snapshots |
            Select-Object `
                Name,
                SnapshotType,
                CreationTime
    }

    # -----------------------------------------------------------------------
    # FINAL MESSAGE
    # -----------------------------------------------------------------------

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "Baseline capture complete."
    Write-Host "Saved to:"
    Write-Host $TranscriptPath
    Write-Host "============================================================"
}
finally {

    Stop-Transcript
}
