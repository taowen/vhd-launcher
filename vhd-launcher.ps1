param(
    [Parameter(Mandatory = $true)]
    [string]$VhdPath
)

Start-Transcript -Path "vhd-launcher.log" -Append

Write-Host "The vhd file path is: $VhdPath"

Read-Host "Press Enter to exit"

