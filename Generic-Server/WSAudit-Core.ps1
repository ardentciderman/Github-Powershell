<#
.SYNOPSIS
    WSAudit - Windows Server health and compliance auditing framework.

.DESCRIPTION
    Early development version of WSAudit.

    This script performs reusable, read-only Windows health checks and
    stores every result in a common structured format.

    Current checks:

        WIN.SYSTEM.OS
            Collects Windows operating system version and build information.

        WIN.OPERATING.KERNEL_UPTIME
            Reports the amount of time since the Windows kernel last restarted.

        WIN.STORAGE.DISKSPACE
            Checks all local fixed disks against warning and failure
            free-space thresholds.

        WIN.OPERATING.REBOOT_PENDING
            Checks common Windows reboot indicators:
                - Component Based Servicing
                - Windows Update
                - PendingFileRenameOperations

        WIN.SERVICE.*
            Checks a small set of core Windows services:
                - Windows Event Log
                - Windows Management Instrumentation
                - Server
                - Task Scheduler
                - Remote Procedure Call (RPC)

        WIN.STORAGE.PHYSICALDISK
            Checks physical disk health and operational state as exposed
            through the Windows Storage subsystem.

        WIN.PERFORMANCE.MEMORY
            Reports current physical memory utilisation.

        WIN.PERFORMANCE.CPU
            Samples CPU utilisation several times and evaluates average
            utilisation.

        WIN.EVENT.SYSTEM.SUMMARY
            Provides a generic summary of recent Critical and Error events
            in the Windows System log.

        WIN.EVENT.SYSTEM.SAMPLE
            Provides one representative diagnostic sample from each of the
            most common Provider + Event ID groups.

        WIN.EVENT.SERVICE_FAILURE
            Looks specifically for recent Service Control Manager events
            associated with service failures, hangs, timeouts and unexpected
            termination.

        WIN.EVENT.SERVICE_FAILURE.SAMPLE
            Provides representative diagnostic examples of detected service
            failure event groups.

        WIN.EVENT.STORAGE
            Looks for Critical and Error events from Windows storage,
            filesystem, disk and storage-controller providers.

        WIN.EVENT.STORAGE.SAMPLE
            Provides one representative diagnostic event from each detected
            storage Provider + Event ID group.

        WIN.EVENT.UNEXPECTED_SHUTDOWN
            Looks for recent evidence that Windows experienced an unexpected
            shutdown, power loss or bugcheck/system crash.

        WIN.EVENT.UNEXPECTED_SHUTDOWN.SAMPLE
            Provides representative diagnostic examples of detected shutdown
            or crash event groups.

        WIN.EVENT.WHEA
            Detects hardware-error events reported by Windows Hardware Error
            Architecture (WHEA).

            Unlike the generic System check, this check also examines Warning
            level events because corrected hardware errors are commonly
            reported by WHEA at Warning level.

        WIN.EVENT.WHEA.SAMPLE
            Provides representative WHEA diagnostic samples grouped by
            Event ID and event severity.

    Output is deliberately written as individual text blocks rather than
    Format-Table output.

    This is because remote execution systems such as Action1 can truncate
    PowerShell table columns.

    A visible separator is written between each result to improve readability
    in consoles that collapse blank-line spacing.

    IMPORTANT:
        This development version is read-only.
        It makes no configuration changes.

.NOTES
    Project:
        WSAudit

    Development stage:
        Prototype

    Intended execution:
        - Local PowerShell
        - Action1 endpoint execution

    Result statuses:

        PASS
            Check completed and expected condition was met.

        WARN
            Check completed but something requires review.

        FAIL
            Check completed and an unhealthy condition was detected.

        INFO
            Informational result only.

    Planned Action1 exit-code convention:

        0 = PASS or WARN
        1 = FAIL
        2 = Script/runtime failure

    NOTE:
        Exit-code handling has not yet been added to this prototype.

    EVENT CLASSIFICATION PHILOSOPHY:

        Generic event-log checks must not declare a server unhealthy simply
        because Windows recorded an Error or Critical event.

        Event severity is useful context, but reliable health classification
        should also consider:

            - Event ID
            - Provider
            - Frequency
            - Timing
            - Server role
            - Known transient conditions
            - Related events
            - Workload-specific context

        Targeted checks provide stronger context than the generic event
        summary.

        WHEA is treated differently because the provider exists specifically
        to report hardware error conditions.

        Current WHEA classification:

            PASS
                No WHEA hardware-error events detected.

            WARN
                WHEA events exist but none are Critical/Error.

                This commonly includes corrected hardware errors reported
                at Warning level.

            FAIL
                At least one Critical/Error WHEA event exists.

        Representative event data is retained for later investigation and
        future PrePatch/PostPatch comparison.

.EXAMPLE
    PS C:\> .\test.ps1

    Runs all currently implemented WSAudit checks against the local computer.

#>


# =====================================================================
# INITIALISE RESULT COLLECTION
# =====================================================================

$Results = [System.Collections.Generic.List[object]]::new()


# =====================================================================
# FUNCTION: Add-WSAuditResult
# =====================================================================

function Add-WSAuditResult {

    <#
    .SYNOPSIS
        Adds a structured result to the WSAudit result collection.

    .DESCRIPTION
        All WSAudit checks use this function so that health, security,
        storage and workload-specific checks return a consistent object.

        This common format will later allow the same results to be used for:

            - Console output
            - Action1 output
            - JSON reporting
            - HTML reporting
            - Pre/post patch comparison
            - Historical reporting

    .PARAMETER Id
        Stable machine-readable identifier for the check.

    .PARAMETER Category
        Logical area containing the check.

    .PARAMETER Check
        Human-readable name of the check.

    .PARAMETER Resource
        Object being evaluated.

    .PARAMETER Status
        Result status.

        Supported values:
            PASS
            WARN
            FAIL
            INFO

    .PARAMETER Value
        Current measured or detected value.

    .PARAMETER Expected
        Description of the expected condition or threshold.

    .PARAMETER Details
        Human-readable explanation of the result.

    .PARAMETER Data
        Optional structured data associated with the result.

    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [string]$Category,

        [Parameter(Mandatory)]
        [string]$Check,

        [string]$Resource = '',

        [Parameter(Mandatory)]
        [ValidateSet(
            'PASS',
            'WARN',
            'FAIL',
            'INFO'
        )]
        [string]$Status,

        [object]$Value = $null,

        [string]$Expected = '',

        [string]$Details = '',

        [object]$Data = $null
    )

    $Results.Add(
        [PSCustomObject]@{
            Id        = $Id
            Category  = $Category
            Check     = $Check
            Resource  = $Resource
            Status    = $Status
            Value     = $Value
            Expected  = $Expected
            Details   = $Details
            Timestamp = Get-Date
            Data      = $Data
        }
    )
}


# =====================================================================
# FUNCTION: Test-WSAuditOperatingSystem
# =====================================================================

function Test-WSAuditOperatingSystem {

    <#
    .SYNOPSIS
        Collects operating system and kernel uptime information.

    .DESCRIPTION
        Produces two WSAudit results:

            WIN.SYSTEM.OS
                Windows edition, version and build.

            WIN.OPERATING.KERNEL_UPTIME
                Time since Windows last performed a full kernel restart.

        Kernel uptime is used rather than physical power-on time.

        For Windows Server and patch-validation purposes, the last full
        kernel restart is the useful operational measurement.

    .NOTES
        These checks are informational at this stage.

    #>

    [CmdletBinding()]
    param()

    try {

        $OS = Get-CimInstance `
            -ClassName Win32_OperatingSystem `
            -ErrorAction Stop

        $Now = Get-Date
        $Uptime = $Now - $OS.LastBootUpTime

        $UptimeDays = [math]::Floor(
            $Uptime.TotalDays
        )

        $UptimeHours = $Uptime.Hours

        $UptimeDisplay = "$UptimeDays days $UptimeHours hours"


        Add-WSAuditResult `
            -Id 'WIN.SYSTEM.OS' `
            -Category 'System' `
            -Check 'Operating System' `
            -Resource $env:COMPUTERNAME `
            -Status 'INFO' `
            -Value $OS.Caption `
            -Expected 'Windows Server' `
            -Details (
                "Version $($OS.Version) | " +
                "Build $($OS.BuildNumber)"
            ) `
            -Data ([PSCustomObject]@{
                Caption     = $OS.Caption
                Version     = $OS.Version
                BuildNumber = $OS.BuildNumber
            })


        Add-WSAuditResult `
            -Id 'WIN.OPERATING.KERNEL_UPTIME' `
            -Category 'Operational' `
            -Check 'Kernel Uptime' `
            -Resource $env:COMPUTERNAME `
            -Status 'INFO' `
            -Value $UptimeDisplay `
            -Expected 'Informational' `
            -Details (
                "Last OS restart: " +
                $OS.LastBootUpTime.ToString(
                    'yyyy-MM-dd HH:mm:ss'
                )
            ) `
            -Data ([PSCustomObject]@{
                LastBootTime = $OS.LastBootUpTime
                UptimeDays   = $UptimeDays
                UptimeHours  = $UptimeHours
                TotalHours   = [math]::Round(
                    $Uptime.TotalHours,
                    1
                )
            })
    }
    catch {

        Add-WSAuditResult `
            -Id 'WIN.SYSTEM.OS' `
            -Category 'System' `
            -Check 'Operating System' `
            -Resource $env:COMPUTERNAME `
            -Status 'WARN' `
            -Expected 'OS information available' `
            -Details (
                "Unable to retrieve operating system information: " +
                $_.Exception.Message
            )
    }
}


# =====================================================================
# FUNCTION: Test-WSAuditDiskSpace
# =====================================================================

function Test-WSAuditDiskSpace {

    <#
    .SYNOPSIS
        Checks free space on all local fixed disks.

    .DESCRIPTION
        One WSAudit result is generated for each local fixed disk.

        Default thresholds:

            PASS
                Free space is 15% or greater.

            WARN
                Free space is below 15% but at least 8%.

            FAIL
                Free space is below 8%.

    #>

    [CmdletBinding()]
    param(
        [ValidateRange(1,100)]
        [int]$WarningPercent = 15,

        [ValidateRange(1,100)]
        [int]$FailurePercent = 8
    )

    try {

        $Disks = @(
            Get-CimInstance `
                -ClassName Win32_LogicalDisk `
                -Filter "DriveType=3" `
                -ErrorAction Stop
        )

        foreach ($Disk in $Disks) {

            if (
                -not $Disk.Size -or
                $Disk.Size -le 0
            ) {
                continue
            }

            $FreeGB = [math]::Round(
                $Disk.FreeSpace / 1GB,
                1
            )

            $SizeGB = [math]::Round(
                $Disk.Size / 1GB,
                1
            )

            $FreePercent = [math]::Round(
                (
                    $Disk.FreeSpace /
                    $Disk.Size
                ) * 100,
                1
            )


            if ($FreePercent -lt $FailurePercent) {

                $Status = 'FAIL'
            }
            elseif ($FreePercent -lt $WarningPercent) {

                $Status = 'WARN'
            }
            else {

                $Status = 'PASS'
            }


            Add-WSAuditResult `
                -Id 'WIN.STORAGE.DISKSPACE' `
                -Category 'Storage' `
                -Check 'Disk Space' `
                -Resource $Disk.DeviceID `
                -Status $Status `
                -Value "$FreePercent%" `
                -Expected ">= $WarningPercent% free" `
                -Details "$FreeGB GB free of $SizeGB GB" `
                -Data ([PSCustomObject]@{
                    Drive       = $Disk.DeviceID
                    FreeGB      = $FreeGB
                    SizeGB      = $SizeGB
                    FreePercent = $FreePercent
                })
        }
    }
    catch {

        Add-WSAuditResult `
            -Id 'WIN.STORAGE.DISKSPACE' `
            -Category 'Storage' `
            -Check 'Disk Space' `
            -Resource $env:COMPUTERNAME `
            -Status 'FAIL' `
            -Expected 'Disk information available' `
            -Details (
                "Unable to retrieve disk information: " +
                $_.Exception.Message
            )
    }
}


# =====================================================================
# FUNCTION: Test-WSAuditPendingReboot
# =====================================================================

function Test-WSAuditPendingReboot {

    <#
    .SYNOPSIS
        Determines whether Windows indicates that a reboot may be required.

    .DESCRIPTION
        Checks:

            - Component Based Servicing
            - Windows Update
            - Pending file rename operations

        PASS
            No reboot indicators detected.

        WARN
            One or more reboot indicators detected.

    #>

    [CmdletBinding()]
    param()

    try {

        $Reasons = [System.Collections.Generic.List[string]]::new()

        $CBSRebootPending = Test-Path `
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'

        $WindowsUpdateReboot = Test-Path `
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'

        $PendingRenameProperty = Get-ItemProperty `
            -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
            -Name PendingFileRenameOperations `
            -ErrorAction SilentlyContinue

        $PendingFileRename = $null -ne $PendingRenameProperty


        if ($CBSRebootPending) {
            $Reasons.Add('Component Based Servicing')
        }

        if ($WindowsUpdateReboot) {
            $Reasons.Add('Windows Update')
        }

        if ($PendingFileRename) {
            $Reasons.Add('Pending file operations')
        }


        if ($Reasons.Count -gt 0) {

            Add-WSAuditResult `
                -Id 'WIN.OPERATING.REBOOT_PENDING' `
                -Category 'Operational' `
                -Check 'Pending Reboot' `
                -Resource $env:COMPUTERNAME `
                -Status 'WARN' `
                -Value $true `
                -Expected 'No pending reboot' `
                -Details ($Reasons -join ', ') `
                -Data ([PSCustomObject]@{
                    CBS               = $CBSRebootPending
                    WindowsUpdate     = $WindowsUpdateReboot
                    PendingFileRename = $PendingFileRename
                })
        }
        else {

            Add-WSAuditResult `
                -Id 'WIN.OPERATING.REBOOT_PENDING' `
                -Category 'Operational' `
                -Check 'Pending Reboot' `
                -Resource $env:COMPUTERNAME `
                -Status 'PASS' `
                -Value $false `
                -Expected 'No pending reboot' `
                -Details 'No reboot indicators detected.' `
                -Data ([PSCustomObject]@{
                    CBS               = $CBSRebootPending
                    WindowsUpdate     = $WindowsUpdateReboot
                    PendingFileRename = $PendingFileRename
                })
        }
    }
    catch {

        Add-WSAuditResult `
            -Id 'WIN.OPERATING.REBOOT_PENDING' `
            -Category 'Operational' `
            -Check 'Pending Reboot' `
            -Resource $env:COMPUTERNAME `
            -Status 'WARN' `
            -Expected 'Reboot state detectable' `
            -Details (
                "Unable to determine reboot state: " +
                $_.Exception.Message
            )
    }
}


# =====================================================================
# FUNCTION: Test-WSAuditCriticalServices
# =====================================================================

function Test-WSAuditCriticalServices {

    <#
    .SYNOPSIS
        Checks the state of core Windows services.

    .DESCRIPTION
        Current services:

            EventLog
            Winmgmt
            LanmanServer
            Schedule
            RpcSs

        PASS
            Service is running.

        FAIL
            Service exists but is not running.

        WARN
            Service cannot be found or queried.

    .NOTES
        Workload-specific services are deliberately excluded.

    #>

    [CmdletBinding()]
    param()

    $CriticalServices = @(
        [PSCustomObject]@{
            Name        = 'EventLog'
            DisplayName = 'Windows Event Log'
        }

        [PSCustomObject]@{
            Name        = 'Winmgmt'
            DisplayName = 'Windows Management Instrumentation'
        }

        [PSCustomObject]@{
            Name        = 'LanmanServer'
            DisplayName = 'Server'
        }

        [PSCustomObject]@{
            Name        = 'Schedule'
            DisplayName = 'Task Scheduler'
        }

        [PSCustomObject]@{
            Name        = 'RpcSs'
            DisplayName = 'Remote Procedure Call (RPC)'
        }
    )

    foreach ($ServiceDefinition in $CriticalServices) {

        try {

            $Service = Get-Service `
                -Name $ServiceDefinition.Name `
                -ErrorAction Stop

            if ($Service.Status -eq 'Running') {
                $Status = 'PASS'
            }
            else {
                $Status = 'FAIL'
            }


            Add-WSAuditResult `
                -Id "WIN.SERVICE.$($ServiceDefinition.Name.ToUpper())" `
                -Category 'Services' `
                -Check 'Critical Windows Service' `
                -Resource $ServiceDefinition.Name `
                -Status $Status `
                -Value $Service.Status `
                -Expected 'Running' `
                -Details (
                    "$($ServiceDefinition.DisplayName) " +
                    "($($ServiceDefinition.Name)) is $($Service.Status)."
                ) `
                -Data ([PSCustomObject]@{
                    ServiceName = $ServiceDefinition.Name
                    DisplayName = $Service.DisplayName
                    Status      = $Service.Status.ToString()
                    CanStop     = $Service.CanStop
                })
        }
        catch {

            Add-WSAuditResult `
                -Id "WIN.SERVICE.$($ServiceDefinition.Name.ToUpper())" `
                -Category 'Services' `
                -Check 'Critical Windows Service' `
                -Resource $ServiceDefinition.Name `
                -Status 'WARN' `
                -Expected 'Service present and running' `
                -Details (
                    "Unable to query service " +
                    "$($ServiceDefinition.DisplayName) " +
                    "($($ServiceDefinition.Name)): " +
                    $_.Exception.Message
                )
        }
    }
}


# =====================================================================
# FUNCTION: Test-WSAuditPhysicalDiskHealth
# =====================================================================

function Test-WSAuditPhysicalDiskHealth {

    <#
    .SYNOPSIS
        Checks physical disk health as exposed by Windows.

    .DESCRIPTION
        Uses Get-PhysicalDisk.

        PASS
            Healthy and OperationalStatus OK.

        WARN
            Non-normal state not explicitly classified as a failure.

        FAIL
            Unhealthy, communication failure, error, or predictive failure.

    .NOTES
        Virtualisation, RAID and SAN systems may abstract actual hardware.

        WSAudit reports what Windows can see.

    #>

    [CmdletBinding()]
    param()

    try {

        $PhysicalDisks = @(
            Get-PhysicalDisk -ErrorAction Stop
        )


        if ($PhysicalDisks.Count -eq 0) {

            Add-WSAuditResult `
                -Id 'WIN.STORAGE.PHYSICALDISK' `
                -Category 'Storage' `
                -Check 'Physical Disk Health' `
                -Resource $env:COMPUTERNAME `
                -Status 'WARN' `
                -Value 'No disks returned' `
                -Expected 'Physical disk information available' `
                -Details (
                    'Get-PhysicalDisk completed successfully but returned ' +
                    'no physical disk objects.'
                )

            return
        }


        foreach ($Disk in $PhysicalDisks) {

            $HealthStatus = $Disk.HealthStatus.ToString()

            $OperationalStatus = (
                @($Disk.OperationalStatus) |
                    ForEach-Object {
                        $_.ToString()
                    }
            ) -join ', '

            $SizeGB = [math]::Round(
                $Disk.Size / 1GB,
                1
            )


            $FailureStates = @(
                'Unhealthy',
                'Lost Communication',
                'No Contact',
                'Error',
                'Predictive Failure'
            )

            $HasFailureState = $false

            foreach ($FailureState in $FailureStates) {

                if (
                    $HealthStatus -eq $FailureState -or
                    $OperationalStatus -match [regex]::Escape(
                        $FailureState
                    )
                ) {

                    $HasFailureState = $true
                    break
                }
            }


            if ($HasFailureState) {
                $Status = 'FAIL'
            }
            elseif (
                $HealthStatus -eq 'Healthy' -and
                $OperationalStatus -eq 'OK'
            ) {
                $Status = 'PASS'
            }
            else {
                $Status = 'WARN'
            }


            if ($null -ne $Disk.DeviceId) {

                $Resource = (
                    "$($Disk.FriendlyName) " +
                    "(Device $($Disk.DeviceId))"
                )
            }
            else {
                $Resource = $Disk.FriendlyName
            }


            Add-WSAuditResult `
                -Id 'WIN.STORAGE.PHYSICALDISK' `
                -Category 'Storage' `
                -Check 'Physical Disk Health' `
                -Resource $Resource `
                -Status $Status `
                -Value $HealthStatus `
                -Expected 'Healthy / OK' `
                -Details (
                    "Operational status: $OperationalStatus | " +
                    "Media: $($Disk.MediaType) | " +
                    "Bus: $($Disk.BusType) | " +
                    "Size: $SizeGB GB"
                ) `
                -Data ([PSCustomObject]@{
                    DeviceId          = $Disk.DeviceId
                    FriendlyName      = $Disk.FriendlyName
                    SerialNumber      = $Disk.SerialNumber
                    MediaType         = $Disk.MediaType.ToString()
                    BusType           = $Disk.BusType.ToString()
                    SizeGB            = $SizeGB
                    HealthStatus      = $HealthStatus
                    OperationalStatus = $OperationalStatus
                })
        }
    }
    catch {

        Add-WSAuditResult `
            -Id 'WIN.STORAGE.PHYSICALDISK' `
            -Category 'Storage' `
            -Check 'Physical Disk Health' `
            -Resource $env:COMPUTERNAME `
            -Status 'WARN' `
            -Value 'Unavailable' `
            -Expected 'Physical disk information available' `
            -Details (
                "Unable to retrieve physical disk health: " +
                $_.Exception.Message
            )
    }
}


# =====================================================================
# FUNCTION: Test-WSAuditMemory
# =====================================================================

function Test-WSAuditMemory {

    <#
    .SYNOPSIS
        Checks current physical memory utilisation.

    .DESCRIPTION
        Default thresholds:

            PASS
                Below 85% used.

            WARN
                85% or greater but below 95%.

            FAIL
                95% or greater.

        This is a point-in-time measurement.

    #>

    [CmdletBinding()]
    param(
        [ValidateRange(1,100)]
        [int]$WarningPercent = 85,

        [ValidateRange(1,100)]
        [int]$FailurePercent = 95
    )

    try {

        $OS = Get-CimInstance `
            -ClassName Win32_OperatingSystem `
            -ErrorAction Stop


        $TotalMemoryKB = [double]$OS.TotalVisibleMemorySize
        $FreeMemoryKB  = [double]$OS.FreePhysicalMemory


        if ($TotalMemoryKB -le 0) {
            throw 'Windows returned an invalid total physical memory value.'
        }


        $UsedMemoryKB = (
            $TotalMemoryKB -
            $FreeMemoryKB
        )


        $TotalMemoryGB = [math]::Round(
            $TotalMemoryKB / 1MB,
            1
        )

        $FreeMemoryGB = [math]::Round(
            $FreeMemoryKB / 1MB,
            1
        )

        $UsedMemoryGB = [math]::Round(
            $UsedMemoryKB / 1MB,
            1
        )


        $UsedPercent = [math]::Round(
            (
                $UsedMemoryKB /
                $TotalMemoryKB
            ) * 100,
            1
        )


        if ($UsedPercent -ge $FailurePercent) {
            $Status = 'FAIL'
        }
        elseif ($UsedPercent -ge $WarningPercent) {
            $Status = 'WARN'
        }
        else {
            $Status = 'PASS'
        }


        Add-WSAuditResult `
            -Id 'WIN.PERFORMANCE.MEMORY' `
            -Category 'Performance' `
            -Check 'Memory Utilisation' `
            -Resource $env:COMPUTERNAME `
            -Status $Status `
            -Value "$UsedPercent% used" `
            -Expected "< $WarningPercent% used" `
            -Details (
                "$UsedMemoryGB GB used | " +
                "$FreeMemoryGB GB free | " +
                "$TotalMemoryGB GB total"
            ) `
            -Data ([PSCustomObject]@{
                TotalMemoryGB = $TotalMemoryGB
                UsedMemoryGB  = $UsedMemoryGB
                FreeMemoryGB  = $FreeMemoryGB
                UsedPercent   = $UsedPercent
                WarningLevel  = $WarningPercent
                FailureLevel  = $FailurePercent
            })
    }
    catch {

        Add-WSAuditResult `
            -Id 'WIN.PERFORMANCE.MEMORY' `
            -Category 'Performance' `
            -Check 'Memory Utilisation' `
            -Resource $env:COMPUTERNAME `
            -Status 'WARN' `
            -Value 'Unavailable' `
            -Expected 'Memory information available' `
            -Details (
                "Unable to retrieve memory information: " +
                $_.Exception.Message
            )
    }
}


# =====================================================================
# FUNCTION: Test-WSAuditCPU
# =====================================================================

function Test-WSAuditCPU {

    <#
    .SYNOPSIS
        Checks CPU utilisation using multiple short-duration samples.

    .DESCRIPTION
        By default:

            5 samples are collected.
            Samples are one second apart.

        Default thresholds apply to average CPU utilisation:

            PASS
                Average CPU below 85%.

            WARN
                Average CPU 85% or greater but below 95%.

            FAIL
                Average CPU 95% or greater.

        Peak CPU is reported for context but does not determine status.

    #>

    [CmdletBinding()]
    param(
        [ValidateRange(1,100)]
        [int]$WarningPercent = 85,

        [ValidateRange(1,100)]
        [int]$FailurePercent = 95,

        [ValidateRange(1,60)]
        [int]$SampleCount = 5,

        [ValidateRange(1,30)]
        [int]$SampleIntervalSeconds = 1
    )

    try {

        $Samples = [System.Collections.Generic.List[double]]::new()


        for (
            $SampleNumber = 1
            $SampleNumber -le $SampleCount
            $SampleNumber++
        ) {

            $Processors = @(
                Get-CimInstance `
                    -ClassName Win32_Processor `
                    -ErrorAction Stop
            )


            if ($Processors.Count -eq 0) {
                throw 'Windows returned no processor information.'
            }


            $ValidProcessorValues = @(
                $Processors |
                    Where-Object {
                        $null -ne $_.LoadPercentage
                    } |
                    ForEach-Object {
                        [double]$_.LoadPercentage
                    }
            )


            if ($ValidProcessorValues.Count -eq 0) {
                throw 'Windows returned no valid CPU utilisation values.'
            }


            $CurrentSample = [math]::Round(
                (
                    $ValidProcessorValues |
                        Measure-Object -Average
                ).Average,
                1
            )

            $Samples.Add(
                $CurrentSample
            )


            if ($SampleNumber -lt $SampleCount) {

                Start-Sleep `
                    -Seconds $SampleIntervalSeconds
            }
        }


        $AverageCPU = [math]::Round(
            (
                $Samples |
                    Measure-Object -Average
            ).Average,
            1
        )

        $PeakCPU = [math]::Round(
            (
                $Samples |
                    Measure-Object -Maximum
            ).Maximum,
            1
        )


        if ($AverageCPU -ge $FailurePercent) {
            $Status = 'FAIL'
        }
        elseif ($AverageCPU -ge $WarningPercent) {
            $Status = 'WARN'
        }
        else {
            $Status = 'PASS'
        }


        $ComputerSystem = Get-CimInstance `
            -ClassName Win32_ComputerSystem `
            -ErrorAction Stop

        $LogicalProcessors = $ComputerSystem.NumberOfLogicalProcessors


        $SampleDisplay = (
            $Samples |
                ForEach-Object {
                    "$_%"
                }
        ) -join ', '


        Add-WSAuditResult `
            -Id 'WIN.PERFORMANCE.CPU' `
            -Category 'Performance' `
            -Check 'CPU Utilisation' `
            -Resource $env:COMPUTERNAME `
            -Status $Status `
            -Value "$AverageCPU% average" `
            -Expected "< $WarningPercent% average" `
            -Details (
                "Peak: $PeakCPU% | " +
                "Samples: $SampleDisplay | " +
                "Logical processors: $LogicalProcessors"
            ) `
            -Data ([PSCustomObject]@{
                AveragePercent    = $AverageCPU
                PeakPercent       = $PeakCPU
                Samples           = @($Samples)
                SampleCount       = $SampleCount
                SampleInterval    = $SampleIntervalSeconds
                LogicalProcessors = $LogicalProcessors
                WarningLevel      = $WarningPercent
                FailureLevel      = $FailurePercent
            })
    }
    catch {

        Add-WSAuditResult `
            -Id 'WIN.PERFORMANCE.CPU' `
            -Category 'Performance' `
            -Check 'CPU Utilisation' `
            -Resource $env:COMPUTERNAME `
            -Status 'WARN' `
            -Value 'Unavailable' `
            -Expected 'CPU utilisation available' `
            -Details (
                "Unable to retrieve CPU utilisation: " +
                $_.Exception.Message
            )
    }
}


# =====================================================================
# FUNCTION: Test-WSAuditSystemEvents
# =====================================================================

function Test-WSAuditSystemEvents {

    <#
    .SYNOPSIS
        Summarises System Critical/Error events and provides representative
        samples from the most common event groups.

    .DESCRIPTION
        Examines the Windows System event log over a configurable lookback.

        Generic Windows event severity does not generate FAIL.

        Targeted checks are responsible for applying additional context.

    #>

    [CmdletBinding()]
    param(
        [ValidateRange(1,720)]
        [int]$LookbackHours = 24,

        [ValidateRange(1,20)]
        [int]$TopEventGroups = 5,

        [ValidateRange(80,1000)]
        [int]$MessageLength = 220
    )

    try {

        $null = Get-WinEvent `
            -ListLog 'System' `
            -ErrorAction Stop


        $StartTime = (Get-Date).AddHours(
            -$LookbackHours
        )


        $Events = @(
            Get-WinEvent `
                -FilterHashtable @{
                    LogName   = 'System'
                    Level     = 1,2
                    StartTime = $StartTime
                } `
                -ErrorAction SilentlyContinue
        )


        $CriticalEvents = @(
            $Events |
                Where-Object {
                    $_.Level -eq 1
                }
        )

        $ErrorEvents = @(
            $Events |
                Where-Object {
                    $_.Level -eq 2
                }
        )

        $CriticalCount = $CriticalEvents.Count
        $ErrorCount    = $ErrorEvents.Count
        $TotalCount    = $Events.Count


        $EventGroups = @(
            $Events |
                Group-Object {
                    "$($_.ProviderName)|$($_.Id)"
                } |
                Sort-Object Count -Descending
        )


        $SelectedGroups = @(
            $EventGroups |
                Select-Object -First $TopEventGroups
        )


        $TopGroups = @(
            $SelectedGroups |
                ForEach-Object {

                    $Parts = $_.Name -split '\|', 2

                    [PSCustomObject]@{
                        Provider = $Parts[0]
                        EventId  = $Parts[1]
                        Count    = $_.Count
                    }
                }
        )


        if ($TopGroups.Count -gt 0) {

            $TopGroupDisplay = (
                $TopGroups |
                    ForEach-Object {
                        "$($_.Provider) ID $($_.EventId) ($($_.Count))"
                    }
            ) -join ', '
        }
        else {
            $TopGroupDisplay = 'None'
        }


        if ($TotalCount -eq 0) {

            $Status = 'PASS'
            $Value  = '0 events'

            $Details = (
                "No Critical or Error System events detected in the last " +
                "$LookbackHours hours."
            )
        }
        else {

            $Status = 'WARN'
            $Value  = "$TotalCount events"

            $Details = (
                "Critical: $CriticalCount | " +
                "Errors: $ErrorCount | " +
                "Top events: $TopGroupDisplay"
            )
        }


        Add-WSAuditResult `
            -Id 'WIN.EVENT.SYSTEM.SUMMARY' `
            -Category 'Events' `
            -Check 'System Event Summary' `
            -Resource 'System' `
            -Status $Status `
            -Value $Value `
            -Expected "No Critical/Error events in last $LookbackHours hours" `
            -Details $Details `
            -Data ([PSCustomObject]@{
                LookbackHours = $LookbackHours
                StartTime     = $StartTime
                TotalCount    = $TotalCount
                CriticalCount = $CriticalCount
                ErrorCount    = $ErrorCount
                TopGroups     = $TopGroups
            })


        foreach ($Group in $SelectedGroups) {

            $Parts = $Group.Name -split '\|', 2

            $ProviderName = $Parts[0]
            $EventId      = [int]$Parts[1]


            $RepresentativeEvent = (
                $Group.Group |
                    Sort-Object TimeCreated -Descending |
                    Select-Object -First 1
            )


            if ($null -eq $RepresentativeEvent) {
                continue
            }


            $Message = [string]$RepresentativeEvent.Message

            if ([string]::IsNullOrWhiteSpace($Message)) {
                $Message = 'No event message was available.'
            }
            else {

                $Message = $Message `
                    -replace '[\r\n\t]+', ' ' `
                    -replace '\s{2,}', ' '

                $Message = $Message.Trim()
            }


            if ($Message.Length -gt $MessageLength) {

                $Message = (
                    $Message.Substring(
                        0,
                        $MessageLength
                    ).TrimEnd() +
                    '...'
                )
            }


            $EventTime = $RepresentativeEvent.TimeCreated.ToString(
                'yyyy-MM-dd HH:mm:ss'
            )

            $LevelName = $RepresentativeEvent.LevelDisplayName

            if ([string]::IsNullOrWhiteSpace($LevelName)) {
                $LevelName = "Level $($RepresentativeEvent.Level)"
            }


            Add-WSAuditResult `
                -Id 'WIN.EVENT.SYSTEM.SAMPLE' `
                -Category 'Events' `
                -Check 'System Event Sample' `
                -Resource "$ProviderName / ID $EventId" `
                -Status 'INFO' `
                -Value "$LevelName | $EventTime" `
                -Expected 'Representative diagnostic sample' `
                -Details $Message `
                -Data ([PSCustomObject]@{
                    TimeCreated  = $RepresentativeEvent.TimeCreated
                    ProviderName = $ProviderName
                    EventId      = $EventId
                    Level        = $RepresentativeEvent.Level
                    LevelName    = $LevelName
                    RecordId     = $RepresentativeEvent.RecordId
                    GroupCount   = $Group.Count
                    Message      = $Message
                })
        }
    }
    catch {

        Add-WSAuditResult `
            -Id 'WIN.EVENT.SYSTEM.SUMMARY' `
            -Category 'Events' `
            -Check 'System Event Summary' `
            -Resource 'System' `
            -Status 'WARN' `
            -Value 'Unavailable' `
            -Expected 'System event log accessible' `
            -Details (
                "Unable to query the System event log: " +
                $_.Exception.Message
            )
    }
}


# =====================================================================
# FUNCTION: Test-WSAuditServiceFailureEvents
# =====================================================================

function Test-WSAuditServiceFailureEvents {

    <#
    .SYNOPSIS
        Checks for recent Windows Service Control Manager failure events.

    .DESCRIPTION
        Monitored Event IDs:

            7000
            7001
            7009
            7011
            7022
            7023
            7024
            7031
            7034

        PASS
            No matching events.

        WARN
            One or more matching events.

        Historical service events do not automatically represent current
        server failure.

    #>

    [CmdletBinding()]
    param(
        [ValidateRange(1,720)]
        [int]$LookbackHours = 24,

        [ValidateRange(80,1000)]
        [int]$MessageLength = 300
    )

    try {

        $StartTime = (Get-Date).AddHours(
            -$LookbackHours
        )


        $MonitoredEventIds = @(
            7000,
            7001,
            7009,
            7011,
            7022,
            7023,
            7024,
            7031,
            7034
        )


        $Events = @(
            Get-WinEvent `
                -FilterHashtable @{
                    LogName      = 'System'
                    ProviderName = 'Service Control Manager'
                    Id           = $MonitoredEventIds
                    StartTime    = $StartTime
                } `
                -ErrorAction SilentlyContinue
        )


        $EventCount = $Events.Count


        $Groups = @(
            $Events |
                Group-Object Id |
                Sort-Object Count -Descending
        )


        if ($Groups.Count -gt 0) {

            $GroupDisplay = (
                $Groups |
                    ForEach-Object {
                        "ID $($_.Name) ($($_.Count))"
                    }
            ) -join ', '
        }
        else {
            $GroupDisplay = 'None'
        }


        if ($EventCount -eq 0) {

            $Status = 'PASS'

            $Details = (
                "No monitored Service Control Manager failure events " +
                "detected in the last $LookbackHours hours."
            )
        }
        else {

            $Status = 'WARN'

            $Details = (
                "$EventCount service failure event(s) detected | " +
                "$GroupDisplay"
            )
        }


        Add-WSAuditResult `
            -Id 'WIN.EVENT.SERVICE_FAILURE' `
            -Category 'Events' `
            -Check 'Service Failure Events' `
            -Resource 'Service Control Manager' `
            -Status $Status `
            -Value "$EventCount events" `
            -Expected "0 monitored service failure events in last $LookbackHours hours" `
            -Details $Details `
            -Data ([PSCustomObject]@{
                LookbackHours     = $LookbackHours
                StartTime         = $StartTime
                EventCount        = $EventCount
                MonitoredEventIds = $MonitoredEventIds
            })


        foreach ($Group in $Groups) {

            $RepresentativeEvent = (
                $Group.Group |
                    Sort-Object TimeCreated -Descending |
                    Select-Object -First 1
            )


            if ($null -eq $RepresentativeEvent) {
                continue
            }


            $Message = [string]$RepresentativeEvent.Message

            if ([string]::IsNullOrWhiteSpace($Message)) {
                $Message = 'No event message was available.'
            }
            else {

                $Message = $Message `
                    -replace '[\r\n\t]+', ' ' `
                    -replace '\s{2,}', ' '

                $Message = $Message.Trim()
            }


            if ($Message.Length -gt $MessageLength) {

                $Message = (
                    $Message.Substring(
                        0,
                        $MessageLength
                    ).TrimEnd() +
                    '...'
                )
            }


            $EventTime = $RepresentativeEvent.TimeCreated.ToString(
                'yyyy-MM-dd HH:mm:ss'
            )


            Add-WSAuditResult `
                -Id 'WIN.EVENT.SERVICE_FAILURE.SAMPLE' `
                -Category 'Events' `
                -Check 'Service Failure Event Sample' `
                -Resource "Service Control Manager / ID $($RepresentativeEvent.Id)" `
                -Status 'INFO' `
                -Value $EventTime `
                -Expected 'Representative diagnostic sample' `
                -Details $Message `
                -Data ([PSCustomObject]@{
                    TimeCreated  = $RepresentativeEvent.TimeCreated
                    ProviderName = $RepresentativeEvent.ProviderName
                    EventId      = $RepresentativeEvent.Id
                    Level        = $RepresentativeEvent.Level
                    LevelName    = $RepresentativeEvent.LevelDisplayName
                    RecordId     = $RepresentativeEvent.RecordId
                    GroupCount   = $Group.Count
                    Message      = $Message
                })
        }
    }
    catch {

        Add-WSAuditResult `
            -Id 'WIN.EVENT.SERVICE_FAILURE' `
            -Category 'Events' `
            -Check 'Service Failure Events' `
            -Resource 'Service Control Manager' `
            -Status 'WARN' `
            -Value 'Unavailable' `
            -Expected 'Service Control Manager event history accessible' `
            -Details (
                "Unable to query Service Control Manager failure events: " +
                $_.Exception.Message
            )
    }
}


# =====================================================================
# FUNCTION: Test-WSAuditStorageEvents
# =====================================================================

function Test-WSAuditStorageEvents {

    <#
    .SYNOPSIS
        Checks recent Critical and Error events from Windows storage
        providers.

    .DESCRIPTION
        The System log is queried once and results are filtered in
        PowerShell to avoid provider-registration differences.

        Current providers:

            Disk
            Ntfs
            Microsoft-Windows-Ntfs
            storahci
            stornvme
            storport
            partmgr
            volmgr
            volsnap
            Microsoft-Windows-StorageSpaces-Driver
            Microsoft-Windows-Storage-ClassPnP

        PASS
            No matching storage events.

        WARN
            One or more matching storage events.

    .NOTES
        VDS Basic Provider and Virtual Disk Service remain deliberately
        outside the targeted storage-health classification at this stage.

    #>

    [CmdletBinding()]
    param(
        [ValidateRange(1,720)]
        [int]$LookbackHours = 24,

        [ValidateRange(80,1000)]
        [int]$MessageLength = 300
    )

    try {

        $null = Get-WinEvent `
            -ListLog 'System' `
            -ErrorAction Stop


        $StartTime = (Get-Date).AddHours(
            -$LookbackHours
        )


        $StorageProviders = @(
            'Disk',
            'Ntfs',
            'Microsoft-Windows-Ntfs',
            'storahci',
            'stornvme',
            'storport',
            'partmgr',
            'volmgr',
            'volsnap',
            'Microsoft-Windows-StorageSpaces-Driver',
            'Microsoft-Windows-Storage-ClassPnP'
        )


        $SystemEvents = @(
            Get-WinEvent `
                -FilterHashtable @{
                    LogName   = 'System'
                    Level     = 1,2
                    StartTime = $StartTime
                } `
                -ErrorAction SilentlyContinue
        )


        $Events = @(
            $SystemEvents |
                Where-Object {
                    $StorageProviders -contains $_.ProviderName
                }
        )


        $EventCount = $Events.Count


        $DetectedProviders = @(
            $Events |
                Select-Object -ExpandProperty ProviderName -Unique |
                Sort-Object
        )


        $Groups = @(
            $Events |
                Group-Object {
                    "$($_.ProviderName)|$($_.Id)"
                } |
                Sort-Object Count -Descending
        )


        $GroupData = @(
            $Groups |
                ForEach-Object {

                    $Parts = $_.Name -split '\|', 2

                    [PSCustomObject]@{
                        Provider = $Parts[0]
                        EventId  = [int]$Parts[1]
                        Count    = $_.Count
                    }
                }
        )


        if ($GroupData.Count -gt 0) {

            $GroupDisplay = (
                $GroupData |
                    ForEach-Object {
                        "$($_.Provider) ID $($_.EventId) ($($_.Count))"
                    }
            ) -join ', '
        }
        else {
            $GroupDisplay = 'None'
        }


        if ($EventCount -eq 0) {

            $Status = 'PASS'

            $Details = (
                "No monitored storage Critical or Error events detected " +
                "in the last $LookbackHours hours."
            )
        }
        else {

            $Status = 'WARN'

            $Details = (
                "$EventCount storage event(s) detected | " +
                "$GroupDisplay"
            )
        }


        Add-WSAuditResult `
            -Id 'WIN.EVENT.STORAGE' `
            -Category 'Events' `
            -Check 'Storage Events' `
            -Resource 'System Storage Providers' `
            -Status $Status `
            -Value "$EventCount events" `
            -Expected "0 monitored storage Critical/Error events in last $LookbackHours hours" `
            -Details $Details `
            -Data ([PSCustomObject]@{
                LookbackHours      = $LookbackHours
                StartTime          = $StartTime
                EventCount         = $EventCount
                MonitoredProviders = $StorageProviders
                DetectedProviders  = $DetectedProviders
                Groups             = $GroupData
            })


        foreach ($Group in $Groups) {

            $Parts = $Group.Name -split '\|', 2

            $ProviderName = $Parts[0]
            $EventId      = [int]$Parts[1]


            $RepresentativeEvent = (
                $Group.Group |
                    Sort-Object TimeCreated -Descending |
                    Select-Object -First 1
            )


            if ($null -eq $RepresentativeEvent) {
                continue
            }


            $Message = [string]$RepresentativeEvent.Message

            if ([string]::IsNullOrWhiteSpace($Message)) {
                $Message = 'No event message was available.'
            }
            else {

                $Message = $Message `
                    -replace '[\r\n\t]+', ' ' `
                    -replace '\s{2,}', ' '

                $Message = $Message.Trim()
            }


            if ($Message.Length -gt $MessageLength) {

                $Message = (
                    $Message.Substring(
                        0,
                        $MessageLength
                    ).TrimEnd() +
                    '...'
                )
            }


            $EventTime = $RepresentativeEvent.TimeCreated.ToString(
                'yyyy-MM-dd HH:mm:ss'
            )


            $LevelName = $RepresentativeEvent.LevelDisplayName

            if ([string]::IsNullOrWhiteSpace($LevelName)) {
                $LevelName = "Level $($RepresentativeEvent.Level)"
            }


            Add-WSAuditResult `
                -Id 'WIN.EVENT.STORAGE.SAMPLE' `
                -Category 'Events' `
                -Check 'Storage Event Sample' `
                -Resource "$ProviderName / ID $EventId" `
                -Status 'INFO' `
                -Value "$LevelName | $EventTime" `
                -Expected 'Representative diagnostic sample' `
                -Details $Message `
                -Data ([PSCustomObject]@{
                    TimeCreated  = $RepresentativeEvent.TimeCreated
                    ProviderName = $ProviderName
                    EventId      = $EventId
                    Level        = $RepresentativeEvent.Level
                    LevelName    = $LevelName
                    RecordId     = $RepresentativeEvent.RecordId
                    GroupCount   = $Group.Count
                    Message      = $Message
                })
        }
    }
    catch {

        Add-WSAuditResult `
            -Id 'WIN.EVENT.STORAGE' `
            -Category 'Events' `
            -Check 'Storage Events' `
            -Resource 'System Storage Providers' `
            -Status 'WARN' `
            -Value 'Unavailable' `
            -Expected 'Storage event history accessible' `
            -Details (
                "Unable to query targeted storage events: " +
                $_.Exception.Message
            )
    }
}


# =====================================================================
# FUNCTION: Test-WSAuditUnexpectedShutdownEvents
# =====================================================================

function Test-WSAuditUnexpectedShutdownEvents {

    <#
    .SYNOPSIS
        Checks for recent unexpected shutdown, power-loss and crash events.

    .DESCRIPTION
        Current monitored signatures:

            Microsoft-Windows-Kernel-Power / 41
            EventLog / 6008
            Microsoft-Windows-WER-SystemErrorReporting / 1001
            BugCheck / 1001

        PASS
            No monitored shutdown/crash events.

        WARN
            One or more monitored shutdown/crash events.

        Historical events remain WARN at this stage.

        Future PostPatch comparison can apply stronger classification to new
        events occurring after the PrePatch baseline.

    #>

    [CmdletBinding()]
    param(
        [ValidateRange(1,720)]
        [int]$LookbackHours = 24,

        [ValidateRange(80,1000)]
        [int]$MessageLength = 350
    )

    try {

        $null = Get-WinEvent `
            -ListLog 'System' `
            -ErrorAction Stop


        $StartTime = (Get-Date).AddHours(
            -$LookbackHours
        )


        $SystemEvents = @(
            Get-WinEvent `
                -FilterHashtable @{
                    LogName   = 'System'
                    Level     = 1,2
                    StartTime = $StartTime
                } `
                -ErrorAction SilentlyContinue
        )


        $Events = @(
            $SystemEvents |
                Where-Object {

                    (
                        $_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' -and
                        $_.Id -eq 41
                    ) -or
                    (
                        $_.ProviderName -eq 'EventLog' -and
                        $_.Id -eq 6008
                    ) -or
                    (
                        $_.ProviderName -eq 'Microsoft-Windows-WER-SystemErrorReporting' -and
                        $_.Id -eq 1001
                    ) -or
                    (
                        $_.ProviderName -eq 'BugCheck' -and
                        $_.Id -eq 1001
                    )
                }
        )


        $EventCount = $Events.Count


        $KernelPowerCount = @(
            $Events |
                Where-Object {
                    $_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' -and
                    $_.Id -eq 41
                }
        ).Count


        $UnexpectedShutdownCount = @(
            $Events |
                Where-Object {
                    $_.ProviderName -eq 'EventLog' -and
                    $_.Id -eq 6008
                }
        ).Count


        $BugCheckCount = @(
            $Events |
                Where-Object {

                    $_.Id -eq 1001 -and
                    $_.ProviderName -in @(
                        'Microsoft-Windows-WER-SystemErrorReporting',
                        'BugCheck'
                    )
                }
        ).Count


        $Groups = @(
            $Events |
                Group-Object {
                    "$($_.ProviderName)|$($_.Id)"
                } |
                Sort-Object Count -Descending
        )


        $GroupData = @(
            $Groups |
                ForEach-Object {

                    $Parts = $_.Name -split '\|', 2

                    [PSCustomObject]@{
                        Provider = $Parts[0]
                        EventId  = [int]$Parts[1]
                        Count    = $_.Count
                    }
                }
        )


        if ($GroupData.Count -gt 0) {

            $GroupDisplay = (
                $GroupData |
                    ForEach-Object {
                        "$($_.Provider) ID $($_.EventId) ($($_.Count))"
                    }
            ) -join ', '
        }
        else {
            $GroupDisplay = 'None'
        }


        if ($EventCount -eq 0) {

            $Status = 'PASS'

            $Details = (
                "No monitored unexpected shutdown or system crash events " +
                "detected in the last $LookbackHours hours."
            )
        }
        else {

            $Status = 'WARN'

            $Details = (
                "$EventCount shutdown/crash event(s) detected | " +
                "Kernel-Power 41: $KernelPowerCount | " +
                "Unexpected shutdown 6008: $UnexpectedShutdownCount | " +
                "Bugcheck 1001: $BugCheckCount | " +
                "Groups: $GroupDisplay"
            )
        }


        Add-WSAuditResult `
            -Id 'WIN.EVENT.UNEXPECTED_SHUTDOWN' `
            -Category 'Events' `
            -Check 'Unexpected Shutdown / Crash Events' `
            -Resource 'System' `
            -Status $Status `
            -Value "$EventCount events" `
            -Expected "0 unexpected shutdown/crash events in last $LookbackHours hours" `
            -Details $Details `
            -Data ([PSCustomObject]@{
                LookbackHours           = $LookbackHours
                StartTime               = $StartTime
                EventCount              = $EventCount
                KernelPower41Count      = $KernelPowerCount
                UnexpectedShutdownCount = $UnexpectedShutdownCount
                BugCheckCount           = $BugCheckCount
                Groups                  = $GroupData
            })


        foreach ($Group in $Groups) {

            $Parts = $Group.Name -split '\|', 2

            $ProviderName = $Parts[0]
            $EventId      = [int]$Parts[1]


            $RepresentativeEvent = (
                $Group.Group |
                    Sort-Object TimeCreated -Descending |
                    Select-Object -First 1
            )


            if ($null -eq $RepresentativeEvent) {
                continue
            }


            $Message = [string]$RepresentativeEvent.Message

            if ([string]::IsNullOrWhiteSpace($Message)) {
                $Message = 'No event message was available.'
            }
            else {

                $Message = $Message `
                    -replace '[\r\n\t]+', ' ' `
                    -replace '\s{2,}', ' '

                $Message = $Message.Trim()
            }


            if ($Message.Length -gt $MessageLength) {

                $Message = (
                    $Message.Substring(
                        0,
                        $MessageLength
                    ).TrimEnd() +
                    '...'
                )
            }


            $EventTime = $RepresentativeEvent.TimeCreated.ToString(
                'yyyy-MM-dd HH:mm:ss'
            )


            $LevelName = $RepresentativeEvent.LevelDisplayName

            if ([string]::IsNullOrWhiteSpace($LevelName)) {
                $LevelName = "Level $($RepresentativeEvent.Level)"
            }


            Add-WSAuditResult `
                -Id 'WIN.EVENT.UNEXPECTED_SHUTDOWN.SAMPLE' `
                -Category 'Events' `
                -Check 'Unexpected Shutdown / Crash Event Sample' `
                -Resource "$ProviderName / ID $EventId" `
                -Status 'INFO' `
                -Value "$LevelName | $EventTime" `
                -Expected 'Representative diagnostic sample' `
                -Details $Message `
                -Data ([PSCustomObject]@{
                    TimeCreated  = $RepresentativeEvent.TimeCreated
                    ProviderName = $ProviderName
                    EventId      = $EventId
                    Level        = $RepresentativeEvent.Level
                    LevelName    = $LevelName
                    RecordId     = $RepresentativeEvent.RecordId
                    GroupCount   = $Group.Count
                    Message      = $Message
                })
        }
    }
    catch {

        Add-WSAuditResult `
            -Id 'WIN.EVENT.UNEXPECTED_SHUTDOWN' `
            -Category 'Events' `
            -Check 'Unexpected Shutdown / Crash Events' `
            -Resource 'System' `
            -Status 'WARN' `
            -Value 'Unavailable' `
            -Expected 'Shutdown/crash event history accessible' `
            -Details (
                "Unable to query unexpected shutdown/crash events: " +
                $_.Exception.Message
            )
    }
}


# =====================================================================
# FUNCTION: Test-WSAuditWHEAEvents
# =====================================================================

function Test-WSAuditWHEAEvents {

    <#
    .SYNOPSIS
        Detects hardware errors reported by Windows Hardware Error
        Architecture (WHEA).

    .DESCRIPTION
        Searches the Windows System log for events generated by:

            Microsoft-Windows-WHEA-Logger

        WHEA is Windows' hardware-error reporting architecture.

        Unlike the generic WSAudit System event check, this function does
        not restrict the query to Critical and Error severity.

        This is important because corrected hardware errors can be logged
        at Warning level.

        Examples of conditions WHEA may report include hardware errors
        associated with:

            - Processor cores
            - Machine Check Architecture
            - CPU cache hierarchy
            - Memory
            - PCI Express
            - Storage devices/controllers
            - Platform hardware
            - Device-driver reported hardware conditions

        WSAudit does not attempt to identify the failed physical component
        solely from Event ID.

        The event message and error record provide the diagnostic context.

        Current classification:

            PASS
                No WHEA events detected in the lookback period.

            WARN
                WHEA events exist, but all detected events are below
                Critical/Error severity.

                This typically captures corrected hardware errors.

            FAIL
                One or more WHEA Critical or Error events were detected.

        One representative sample is created for each Event ID + severity
        combination.

    .PARAMETER LookbackHours
        Number of hours of System event history to examine.

        Default:
            24

    .PARAMETER MessageLength
        Maximum length of representative diagnostic event messages.

        Default:
            400 characters

    .NOTES
        Stable summary ID:

            WIN.EVENT.WHEA

        Stable sample ID:

            WIN.EVENT.WHEA.SAMPLE

        This check is read-only.

        It does not modify hardware configuration, firmware, drivers or
        event logs.

        A WHEA Event ID should not by itself be assumed to identify a
        particular failed component.

        Provider, severity, message, frequency and surrounding hardware
        evidence must be considered together.

    .EXAMPLE
        Test-WSAuditWHEAEvents

        Examines WHEA activity during the previous 24 hours.

    #>

    [CmdletBinding()]
    param(
        [ValidateRange(1,720)]
        [int]$LookbackHours = 24,

        [ValidateRange(80,2000)]
        [int]$MessageLength = 400
    )

    try {

        $null = Get-WinEvent `
            -ListLog 'System' `
            -ErrorAction Stop


        $StartTime = (Get-Date).AddHours(
            -$LookbackHours
        )


        $SystemEvents = @(
            Get-WinEvent `
                -FilterHashtable @{
                    LogName   = 'System'
                    StartTime = $StartTime
                } `
                -ErrorAction SilentlyContinue
        )


        $Events = @(
            $SystemEvents |
                Where-Object {
                    $_.ProviderName -eq 'Microsoft-Windows-WHEA-Logger'
                }
        )


        $EventCount = $Events.Count


        $CriticalCount = @(
            $Events |
                Where-Object {
                    $_.Level -eq 1
                }
        ).Count


        $ErrorCount = @(
            $Events |
                Where-Object {
                    $_.Level -eq 2
                }
        ).Count


        $WarningCount = @(
            $Events |
                Where-Object {
                    $_.Level -eq 3
                }
        ).Count


        $InformationCount = @(
            $Events |
                Where-Object {
                    $_.Level -eq 4
                }
        ).Count


        $SevereCount = (
            $CriticalCount +
            $ErrorCount
        )


        $Groups = @(
            $Events |
                Group-Object {
                    "$($_.Id)|$($_.Level)"
                } |
                Sort-Object Count -Descending
        )


        $GroupData = @(
            $Groups |
                ForEach-Object {

                    $Parts = $_.Name -split '\|', 2

                    $Representative = (
                        $_.Group |
                            Select-Object -First 1
                    )

                    $LevelName = $Representative.LevelDisplayName

                    if ([string]::IsNullOrWhiteSpace($LevelName)) {
                        $LevelName = "Level $($Representative.Level)"
                    }

                    [PSCustomObject]@{
                        EventId   = [int]$Parts[0]
                        Level     = [int]$Parts[1]
                        LevelName = $LevelName
                        Count     = $_.Count
                    }
                }
        )


        if ($GroupData.Count -gt 0) {

            $GroupDisplay = (
                $GroupData |
                    ForEach-Object {
                        "ID $($_.EventId) $($_.LevelName) ($($_.Count))"
                    }
            ) -join ', '
        }
        else {
            $GroupDisplay = 'None'
        }


        if ($EventCount -eq 0) {

            $Status = 'PASS'

            $Details = (
                "No WHEA hardware-error events detected in the last " +
                "$LookbackHours hours."
            )
        }
        elseif ($SevereCount -gt 0) {

            $Status = 'FAIL'

            $Details = (
                "$EventCount WHEA event(s) detected | " +
                "Critical: $CriticalCount | " +
                "Errors: $ErrorCount | " +
                "Warnings: $WarningCount | " +
                "Information: $InformationCount | " +
                "Groups: $GroupDisplay"
            )
        }
        else {

            $Status = 'WARN'

            $Details = (
                "$EventCount WHEA event(s) detected with no Critical/Error " +
                "events | Warnings: $WarningCount | " +
                "Information: $InformationCount | " +
                "Groups: $GroupDisplay"
            )
        }


        Add-WSAuditResult `
            -Id 'WIN.EVENT.WHEA' `
            -Category 'Hardware' `
            -Check 'WHEA Hardware Errors' `
            -Resource 'Microsoft-Windows-WHEA-Logger' `
            -Status $Status `
            -Value "$EventCount events" `
            -Expected "0 WHEA hardware-error events in last $LookbackHours hours" `
            -Details $Details `
            -Data ([PSCustomObject]@{
                LookbackHours    = $LookbackHours
                StartTime        = $StartTime
                EventCount       = $EventCount
                CriticalCount    = $CriticalCount
                ErrorCount       = $ErrorCount
                WarningCount     = $WarningCount
                InformationCount = $InformationCount
                SevereCount      = $SevereCount
                Groups           = $GroupData
            })


        foreach ($Group in $Groups) {

            $RepresentativeEvent = (
                $Group.Group |
                    Sort-Object TimeCreated -Descending |
                    Select-Object -First 1
            )


            if ($null -eq $RepresentativeEvent) {
                continue
            }


            $Message = [string]$RepresentativeEvent.Message

            if ([string]::IsNullOrWhiteSpace($Message)) {

                $Message = 'No event message was available.'
            }
            else {

                $Message = $Message `
                    -replace '[\r\n\t]+', ' ' `
                    -replace '\s{2,}', ' '

                $Message = $Message.Trim()
            }


            if ($Message.Length -gt $MessageLength) {

                $Message = (
                    $Message.Substring(
                        0,
                        $MessageLength
                    ).TrimEnd() +
                    '...'
                )
            }


            $EventTime = $RepresentativeEvent.TimeCreated.ToString(
                'yyyy-MM-dd HH:mm:ss'
            )


            $LevelName = $RepresentativeEvent.LevelDisplayName

            if ([string]::IsNullOrWhiteSpace($LevelName)) {
                $LevelName = "Level $($RepresentativeEvent.Level)"
            }


            Add-WSAuditResult `
                -Id 'WIN.EVENT.WHEA.SAMPLE' `
                -Category 'Hardware' `
                -Check 'WHEA Hardware Error Sample' `
                -Resource "WHEA-Logger / ID $($RepresentativeEvent.Id)" `
                -Status 'INFO' `
                -Value "$LevelName | $EventTime" `
                -Expected 'Representative hardware-error diagnostic sample' `
                -Details $Message `
                -Data ([PSCustomObject]@{
                    TimeCreated  = $RepresentativeEvent.TimeCreated
                    ProviderName = $RepresentativeEvent.ProviderName
                    EventId      = $RepresentativeEvent.Id
                    Level        = $RepresentativeEvent.Level
                    LevelName    = $LevelName
                    RecordId     = $RepresentativeEvent.RecordId
                    GroupCount   = $Group.Count
                    Message      = $Message
                })
        }
    }
    catch {

        Add-WSAuditResult `
            -Id 'WIN.EVENT.WHEA' `
            -Category 'Hardware' `
            -Check 'WHEA Hardware Errors' `
            -Resource 'Microsoft-Windows-WHEA-Logger' `
            -Status 'WARN' `
            -Value 'Unavailable' `
            -Expected 'WHEA event history accessible' `
            -Details (
                "Unable to query WHEA hardware-error events: " +
                $_.Exception.Message
            )
    }
}


# =====================================================================
# FUNCTION: Write-WSAuditConsoleOutput
# =====================================================================

function Write-WSAuditConsoleOutput {

    <#
    .SYNOPSIS
        Writes WSAudit results in a console-friendly text format.

    .DESCRIPTION
        Outputs each WSAudit result as a readable text block.

        Format-Table is deliberately not used because remote management
        platforms such as Action1 may flatten or truncate table output.

        A visible separator is written between result blocks because
        Action1 may collapse blank-line spacing.

        This function controls presentation only.

    #>

    [CmdletBinding()]
    param()

    Write-Output ''
    Write-Output '============================================================'
    Write-Output 'WSAudit Results'
    Write-Output "Computer : $env:COMPUTERNAME"
    Write-Output "Run Time : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Output '============================================================'
    Write-Output ''

    foreach ($Result in $Results) {

        Write-Output "[$($Result.Status)] $($Result.Id)"
        Write-Output "  Category : $($Result.Category)"
        Write-Output "  Check    : $($Result.Check)"
        Write-Output "  Resource : $($Result.Resource)"
        Write-Output "  Value    : $($Result.Value)"
        Write-Output "  Expected : $($Result.Expected)"
        Write-Output "  Details  : $($Result.Details)"

        Write-Output ''
        Write-Output '------------------------------------------------------------'
        Write-Output ''
    }

    Write-Output '============================================================'
    Write-Output 'End of WSAudit Results'
    Write-Output '============================================================'
}


# =====================================================================
# RUN WSAUDIT CHECKS
# =====================================================================

Test-WSAuditOperatingSystem

Test-WSAuditDiskSpace

Test-WSAuditPendingReboot

Test-WSAuditCriticalServices

Test-WSAuditPhysicalDiskHealth

Test-WSAuditMemory

Test-WSAuditCPU

Test-WSAuditSystemEvents

Test-WSAuditServiceFailureEvents

Test-WSAuditStorageEvents

Test-WSAuditUnexpectedShutdownEvents

Test-WSAuditWHEAEvents


# =====================================================================
# DISPLAY RESULTS
# =====================================================================

Write-WSAuditConsoleOutput
