# Example: .\Test-WindowsServiceStarted.ps1 -Name 'winrm'

[CmdletBinding()]
param(
    [Parameter()]
    [string]$Name
)

if ((Get-Service -Name $Name).Status -eq 'Running') {
    $true
} else {
    $false
}
