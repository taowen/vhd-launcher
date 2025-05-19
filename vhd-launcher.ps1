param(
    [Parameter(Mandatory = $true)]
    [string]$VhdPath
)

Start-Transcript -Path "vhd-launcher.log" -Append

Write-Host "The vhd file path is: $VhdPath"

$IniPath = $VhdPath -replace '\.vhd$', '.ini'

# read .ini file
$iniContent = Get-Content $IniPath | Where-Object { $_ -match '=' }

# create a hash table to store key-value
$ini = @{}
foreach ($line in $iniContent) {
    $parts = $line -split '=', 2
    if ($parts.Count -eq 2) {
        $key = $parts[0].Trim()
        $value = $parts[1].Trim()
        $ini[$key] = $value
    }
}

# read each configuration
$readonly = $ini['readonly']
$targetDrive = $ini['targetDrive']
$launch = $ini['launch']
$sourceSaveDir = $ini['sourceSaveDir']
$targetSaveDir = $ini['targetSaveDir']

Write-Host "readonly: $readonly"
Write-Host "targetDrive: $targetDrive"
Write-Host "launch: $launch"
Write-Host "sourceSaveDir: $sourceSaveDir"
Write-Host "targetSaveDir: $targetSaveDir"