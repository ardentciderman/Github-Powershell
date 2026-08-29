<#
.SYNOPSIS
    Validates a Hyper-V VM against an expected configuration baseline.

.DESCRIPTION
    This script performs read-only validation of a Hyper-V virtual machine.

    The expected configuration is loaded from a PowerShell data file (.psd1).

    The script compares the live Hyper-V configuration against the values in
    that baseline and reports PASS or FAIL for each item.

    The script currently validates:

        - VM Generation
        - Processor count
        - Startup memory
        - Dynamic Memory state
        - Expected VHDX attachment path
        - VHDX maximum size
        - VHDX type
        - Secure Boot state
        - Secure Boot template
        - Hyper-V virtual switch connection
        - Checkpoint count

    This script DOES NOT modify the VM.

.NOTES
    Intended for Windows Server Hyper-V.

    Example baseline file:

        C:\HyperV-Baselines\Config\LAB-DC01.psd1

    Example usage:

        .\Test-HyperVVMConfiguration.ps1 `
            -ConfigFile "C:\HyperV-Baselines\Config\LAB-DC01.psd1"

    Result convention:

        LASTEXITCODE 0 = VM matches expected configuration
        LASTEXITCODE 2 = Configuration drift detected

.EXAMPLE
    .\Test-HyperVVMConfiguration.ps1 `
        -ConfigFile "C:\HyperV-Baselines\Config\LAB-DC01.psd1"
#>


# ============================================================================
# PARAMETERS
# ============================================================================

[CmdletBinding()]
param (

    # Full path to the PowerShell data file containing the expected VM
    # configuration.
    #
    # Example:
    # C:\HyperV-Baselines\Config\LAB-DC01.psd1

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [ValidateScript({

        if (-not (Test-Path -LiteralPath $_ -PathType Leaf)) {
            throw "Configuration file '$_' does not exist."
        }

        if ([System.IO.Path]::GetExtension($_) -ne '.psd1') {
            throw "Configuration file must use the .psd1 extension."
        }

        $true
    })]
    [string]$ConfigFile
)


# ============================================================================
# INITIALISE RESULT COLLECTION
# ============================================================================

$Results = @()


# ============================================================================
# HELPER FUNCTION - ADD VALIDATION RESULT
# ============================================================================

function Add-ValidationResult {

    param (

        [Parameter(Mandatory)]
        [string]$Check,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Expected,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Actual,

        [Parameter(Mandatory)]
        [ValidateSet(
            'PASS',
            'FAIL',
            'INFO'
        )]
        [string]$Result
    )

    $script:Results += [PSCustomObject]@{
        Check    = $Check
        Expected = $Expected
        Actual   = $Actual
        Result   = $Result
    }
}


# ============================================================================
# LOAD EXPECTED CONFIGURATION
# ============================================================================

try {

    $Config = Import-PowerShellDataFile `
        -Path $ConfigFile `
        -ErrorAction Stop
}
catch {

    Write-Error (
        "Unable to load configuration file '$ConfigFile'. " +
        $_.Exception.Message
    )

    return
}


# ============================================================================
# VALIDATE REQUIRED CONFIGURATION KEYS
# ============================================================================

# These keys must exist in every supported VM baseline file.
#
# This protects against accidentally running the validator against an
# incomplete or incorrectly structured .psd1 file.

$RequiredKeys = @(
    'VMName',
    'Generation',
    'ProcessorCount',
    'StartupMemoryGB',
    'DynamicMemoryEnabled',
    'VHDXPath',
    'VHDSizeGB',
    'VHDType',
    'SecureBootEnabled',
    'SecureBootTemplate',
    'ExpectedSwitchName',
    'ExpectedCheckpointCount'
)


$MissingKeys = @(
    foreach ($Key in $RequiredKeys) {

        if (-not $Config.ContainsKey($Key)) {
            $Key
        }
    }
)


if ($MissingKeys.Count -gt 0) {

    Write-Error (
        "Configuration file is missing required key(s): " +
        ($MissingKeys -join ', ')
    )

    return
}


# ============================================================================
# LOAD EXPECTED VALUES FROM CONFIG FILE
# ============================================================================

# Copy values from the imported baseline into clearly named variables.
#
# These represent DESIRED STATE.
#
# The live Hyper-V configuration queried later represents ACTUAL STATE.

$VMName                  = [string]$Config.VMName
$ExpectedGeneration      = [int]$Config.Generation
$ExpectedProcessorCount  = [int]$Config.ProcessorCount
$ExpectedStartupMemoryGB = [double]$Config.StartupMemoryGB
$ExpectedDynamicMemory   = [bool]$Config.DynamicMemoryEnabled

$ExpectedVHDXPath        = [string]$Config.VHDXPath
$ExpectedVHDSizeGB       = [double]$Config.VHDSizeGB
$ExpectedVHDType         = [string]$Config.VHDType

$ExpectedSecureBoot      = [bool]$Config.SecureBootEnabled
$ExpectedSecureBootTemplate =
    [string]$Config.SecureBootTemplate

$ExpectedSwitchName =
    [string]$Config.ExpectedSwitchName

$ExpectedCheckpointCount =
    [int]$Config.ExpectedCheckpointCount


# ============================================================================
# VALIDATE BASELINE VALUES
# ============================================================================

# Confirm that required string values are not empty.
#
# ExpectedSwitchName is deliberately excluded because an empty value is valid
# and means that no Hyper-V virtual switch should be connected.

$RequiredStringValues = @{
    VMName             = $VMName
    VHDXPath           = $ExpectedVHDXPath
    VHDType            = $ExpectedVHDType
    SecureBootTemplate = $ExpectedSecureBootTemplate
}


foreach ($Item in $RequiredStringValues.GetEnumerator()) {

    if ([string]::IsNullOrWhiteSpace($Item.Value)) {

        Write-Error (
            "Configuration value '$($Item.Key)' cannot be empty."
        )

        return
    }
}


if ($ExpectedProcessorCount -lt 1) {

    Write-Error "ProcessorCount must be at least 1."
    return
}


if ($ExpectedStartupMemoryGB -le 0) {

    Write-Error "StartupMemoryGB must be greater than 0."
    return
}


if ($ExpectedVHDSizeGB -le 0) {

    Write-Error "VHDSizeGB must be greater than 0."
    return
}


if ($ExpectedCheckpointCount -lt 0) {

    Write-Error "ExpectedCheckpointCount cannot be negative."
    return
}


# ============================================================================
# LOCATE VM
# ============================================================================

try {

    $VM = Get-VM `
        -Name $VMName `
        -ErrorAction Stop
}
catch {

    Write-Error "VM '$VMName' could not be found."

    $global:LASTEXITCODE = 2

    return
}


# ============================================================================
# SCRIPT HEADER
# ============================================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "Hyper-V VM Configuration Validation"
Write-Host "============================================================"
Write-Host ""
Write-Host "Host        : $env:COMPUTERNAME"
Write-Host "VM Name     : $VMName"
Write-Host "Config File : $ConfigFile"
Write-Host "Date        : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ""


# ============================================================================
# 1. VM GENERATION
# ============================================================================

$ActualGeneration = $VM.Generation


if ($ActualGeneration -eq $ExpectedGeneration) {

    $Result = 'PASS'
}
else {

    $Result = 'FAIL'
}


Add-ValidationResult `
    -Check "Generation" `
    -Expected $ExpectedGeneration `
    -Actual $ActualGeneration `
    -Result $Result


# ============================================================================
# 2. PROCESSOR COUNT
# ============================================================================

$ActualProcessorCount = $VM.ProcessorCount


if ($ActualProcessorCount -eq $ExpectedProcessorCount) {

    $Result = 'PASS'
}
else {

    $Result = 'FAIL'
}


Add-ValidationResult `
    -Check "ProcessorCount" `
    -Expected $ExpectedProcessorCount `
    -Actual $ActualProcessorCount `
    -Result $Result


# ============================================================================
# 3. STARTUP MEMORY
# ============================================================================

# Hyper-V stores startup memory in bytes.
#
# Convert to GB before comparing with the baseline.

$ActualStartupMemoryGB = [math]::Round(
    $VM.MemoryStartup / 1GB,
    2
)


if ($ActualStartupMemoryGB -eq $ExpectedStartupMemoryGB) {

    $Result = 'PASS'
}
else {

    $Result = 'FAIL'
}


Add-ValidationResult `
    -Check "StartupMemoryGB" `
    -Expected $ExpectedStartupMemoryGB `
    -Actual $ActualStartupMemoryGB `
    -Result $Result


# ============================================================================
# 4. DYNAMIC MEMORY
# ============================================================================

$ActualDynamicMemory = $VM.DynamicMemoryEnabled


if ($ActualDynamicMemory -eq $ExpectedDynamicMemory) {

    $Result = 'PASS'
}
else {

    $Result = 'FAIL'
}


Add-ValidationResult `
    -Check "DynamicMemoryEnabled" `
    -Expected $ExpectedDynamicMemory `
    -Actual $ActualDynamicMemory `
    -Result $Result


# ============================================================================
# 5. VM HARD DISK ATTACHMENTS
# ============================================================================

try {

    $VMDisks = @(
        Get-VMHardDiskDrive `
            -VMName $VMName `
            -ErrorAction Stop
    )
}
catch {

    $VMDisks = @()

    Add-ValidationResult `
        -Check "VHDXPath" `
        -Expected $ExpectedVHDXPath `
        -Actual "Unable to enumerate VM disk attachments." `
        -Result "FAIL"
}


# Search all attached disks for the exact expected path.

$MatchingDisk = $VMDisks |
    Where-Object {
        $_.Path -eq $ExpectedVHDXPath
    } |
    Select-Object -First 1


if ($MatchingDisk) {

    Add-ValidationResult `
        -Check "VHDXPath" `
        -Expected $ExpectedVHDXPath `
        -Actual $MatchingDisk.Path `
        -Result "PASS"
}
elseif ($VMDisks.Count -gt 0) {

    $ActualDiskPaths = (
        $VMDisks |
        Select-Object -ExpandProperty Path
    ) -join "; "


    Add-ValidationResult `
        -Check "VHDXPath" `
        -Expected $ExpectedVHDXPath `
        -Actual $ActualDiskPaths `
        -Result "FAIL"
}
elseif (
    -not (
        $Results |
        Where-Object Check -eq 'VHDXPath'
    )
) {

    Add-ValidationResult `
        -Check "VHDXPath" `
        -Expected $ExpectedVHDXPath `
        -Actual "<No VM hard disks attached>" `
        -Result "FAIL"
}


# ============================================================================
# 6. VHDX PROPERTIES
# ============================================================================

if (
    $MatchingDisk -and
    (Test-Path -LiteralPath $MatchingDisk.Path)
) {

    try {

        $VHD = Get-VHD `
            -Path $MatchingDisk.Path `
            -ErrorAction Stop


        # --------------------------------------------------------------------
        # VHDX SIZE
        # --------------------------------------------------------------------

        $ActualVHDSizeGB = [math]::Round(
            $VHD.Size / 1GB,
            2
        )


        if ($ActualVHDSizeGB -eq $ExpectedVHDSizeGB) {

            $Result = 'PASS'
        }
        else {

            $Result = 'FAIL'
        }


        Add-ValidationResult `
            -Check "VHDSizeGB" `
            -Expected $ExpectedVHDSizeGB `
            -Actual $ActualVHDSizeGB `
            -Result $Result


        # --------------------------------------------------------------------
        # VHDX TYPE
        # --------------------------------------------------------------------

        if ($VHD.VhdType -eq $ExpectedVHDType) {

            $Result = 'PASS'
        }
        else {

            $Result = 'FAIL'
        }


        Add-ValidationResult `
            -Check "VHDType" `
            -Expected $ExpectedVHDType `
            -Actual $VHD.VhdType `
            -Result $Result
    }
    catch {

        Add-ValidationResult `
            -Check "VHDProperties" `
            -Expected "Readable VHDX" `
            -Actual $_.Exception.Message `
            -Result "FAIL"
    }
}
else {

    Add-ValidationResult `
        -Check "VHDProperties" `
        -Expected "Accessible VHDX" `
        -Actual "Expected VHDX is missing or not attached." `
        -Result "FAIL"
}


# ============================================================================
# 7. SECURE BOOT
# ============================================================================

# Secure Boot applies only to Generation 2 VMs.

if ($VM.Generation -eq 2) {

    try {

        $Firmware = Get-VMFirmware `
            -VMName $VMName `
            -ErrorAction Stop


        # Convert Hyper-V's On/Off representation into Boolean form.

        $ActualSecureBoot = (
            $Firmware.SecureBoot -eq 'On'
        )


        if ($ActualSecureBoot -eq $ExpectedSecureBoot) {

            $Result = 'PASS'
        }
        else {

            $Result = 'FAIL'
        }


        Add-ValidationResult `
            -Check "SecureBootEnabled" `
            -Expected $ExpectedSecureBoot `
            -Actual $ActualSecureBoot `
            -Result $Result


        # --------------------------------------------------------------------
        # SECURE BOOT TEMPLATE
        # --------------------------------------------------------------------

        if (
            $Firmware.SecureBootTemplate -eq
            $ExpectedSecureBootTemplate
        ) {

            $Result = 'PASS'
        }
        else {

            $Result = 'FAIL'
        }


        Add-ValidationResult `
            -Check "SecureBootTemplate" `
            -Expected $ExpectedSecureBootTemplate `
            -Actual $Firmware.SecureBootTemplate `
            -Result $Result
    }
    catch {

        Add-ValidationResult `
            -Check "Firmware" `
            -Expected "Readable" `
            -Actual $_.Exception.Message `
            -Result "FAIL"
    }
}
else {

    # If the baseline expects Generation 2 but the live VM is Generation 1,
    # Generation will already fail above.
    #
    # Record the Secure Boot incompatibility as additional evidence.

    Add-ValidationResult `
        -Check "SecureBoot" `
        -Expected "Generation 2 firmware" `
        -Actual "Generation $($VM.Generation)" `
        -Result "FAIL"
}


# ============================================================================
# 8. NETWORK ADAPTER / SWITCH CONNECTION
# ============================================================================

try {

    $NetworkAdapters = @(
        Get-VMNetworkAdapter `
            -VMName $VMName `
            -ErrorAction Stop
    )
}
catch {

    $NetworkAdapters = @()

    Add-ValidationResult `
        -Check "NetworkAdapterCount" `
        -Expected 1 `
        -Actual "Unable to enumerate VM network adapters." `
        -Result "FAIL"
}


# Version 1 assumes one VM network adapter.
#
# We can expand this later for multi-NIC VMs.

if ($NetworkAdapters.Count -eq 1) {

    $ActualSwitchName =
        [string]$NetworkAdapters[0].SwitchName


    if ($ActualSwitchName -eq $ExpectedSwitchName) {

        $Result = 'PASS'
    }
    else {

        $Result = 'FAIL'
    }


    # Make blank switch names human-readable.

    if ([string]::IsNullOrWhiteSpace($ExpectedSwitchName)) {

        $ExpectedSwitchDisplay = "<None>"
    }
    else {

        $ExpectedSwitchDisplay = $ExpectedSwitchName
    }


    if ([string]::IsNullOrWhiteSpace($ActualSwitchName)) {

        $ActualSwitchDisplay = "<None>"
    }
    else {

        $ActualSwitchDisplay = $ActualSwitchName
    }


    Add-ValidationResult `
        -Check "SwitchName" `
        -Expected $ExpectedSwitchDisplay `
        -Actual $ActualSwitchDisplay `
        -Result $Result
}
elseif ($NetworkAdapters.Count -ne 0) {

    Add-ValidationResult `
        -Check "NetworkAdapterCount" `
        -Expected 1 `
        -Actual $NetworkAdapters.Count `
        -Result "FAIL"
}


# ============================================================================
# 9. CHECKPOINT COUNT
# ============================================================================

try {

    $Snapshots = @(
        Get-VMSnapshot `
            -VMName $VMName `
            -ErrorAction Stop
    )

    $ActualCheckpointCount = $Snapshots.Count


    if (
        $ActualCheckpointCount -eq
        $ExpectedCheckpointCount
    ) {

        $Result = 'PASS'
    }
    else {

        $Result = 'FAIL'
    }


    Add-ValidationResult `
        -Check "CheckpointCount" `
        -Expected $ExpectedCheckpointCount `
        -Actual $ActualCheckpointCount `
        -Result $Result
}
catch {

    Add-ValidationResult `
        -Check "CheckpointCount" `
        -Expected $ExpectedCheckpointCount `
        -Actual "Unable to enumerate checkpoints." `
        -Result "FAIL"
}


# ============================================================================
# 10. DISPLAY RESULTS
# ============================================================================

Write-Host ""
Write-Host "=== EXPECTED VS ACTUAL ==="
Write-Host ""


$Results |
    Format-Table `
        Check,
        Expected,
        Actual,
        Result `
        -AutoSize `
        -Wrap


# ============================================================================
# 11. RESULT COUNTS
# ============================================================================

$PassCount = @(
    $Results |
    Where-Object Result -eq 'PASS'
).Count


$FailCount = @(
    $Results |
    Where-Object Result -eq 'FAIL'
).Count


Write-Host ""
Write-Host "PASS : $PassCount"
Write-Host "FAIL : $FailCount"
Write-Host ""


# ============================================================================
# 12. FINAL DECISION
# ============================================================================

if ($FailCount -gt 0) {

    Write-Host "============================================================"
    Write-Host "RESULT: FAIL - CONFIGURATION DRIFT DETECTED"
    Write-Host "============================================================"
    Write-Host ""
    Write-Host "One or more VM settings differ from the desired baseline."
    Write-Host ""
    Write-Host "Review the failed checks before making configuration changes."

    $global:LASTEXITCODE = 2
}
else {

    Write-Host "============================================================"
    Write-Host "RESULT: PASS - VM MATCHES EXPECTED CONFIGURATION"
    Write-Host "============================================================"
    Write-Host ""
    Write-Host "No configuration drift was detected."

    $global:LASTEXITCODE = 0
}
