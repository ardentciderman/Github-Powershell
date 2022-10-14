# If the C drive is available, return true
# Otherwise return false

if (Test-Path -Path 'C:\') {
    $true                      
} else {
    $false
}