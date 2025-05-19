param(
    [Parameter(Mandatory = $true)]
    [string]$VhdPath
)

### 1. setup log file
$currUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currUser)
$IsAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($IsAdmin) {
    $LogPath = Join-Path $PSScriptRoot "vhd-launcher.admin.log"
} else {
    $LogPath = Join-Path $PSScriptRoot "vhd-launcher.log"
}

Start-Transcript -Path $LogPath

### 2. ensure vhd file exists
Write-Host "The raw vhd file path is: $VhdPath"
Write-Host "The resolved vhd file path is: $VhdPath"

### 3. read configuration
$IniPath = $VhdPath -replace '\.vhd$', '.ini'
if (-not ([System.IO.Path]::IsPathRooted($VhdPath))) {
    $VhdPath = Join-Path -Path $PWD -ChildPath $VhdPath
}
$VhdDir = Split-Path -Path $VhdPath -Parent
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

$readonly = $ini['readonly']
$launchDriveLetter = $ini['launchDriveLetter']
$launchExe = $ini['launchExe']

if (-not ([System.IO.Path]::IsPathRooted($targetSaveDir))) {
    $targetSaveDir = Join-Path -Path (Split-Path -Path $VhdPath -Parent) -ChildPath $targetSaveDir
}

if ($launchDriveLetter -eq 'C' -or $launchDriveLetter -eq 'c') {
    Write-Error "Error: launchDriveLetter cannot be C or c. Aborting."
    exit 1
}

$launchPath = "${launchDriveLetter}:\$launchExe"

Write-Host "readonly: $readonly"
Write-Host "launchDriveLetter: $launchDriveLetter"
Write-Host "launchExe: $launchExe"
Write-Host "launchPath: $launchPath"

### 4. if already mounted, launch the exe directly
if (Test-Path $launchPath) {
    Write-Host "launchPath exists, launching: $launchPath"
    Start-Process -FilePath $launchPath
    Stop-Transcript
    exit 0
} else {
    Write-Host "launchPath not found: $launchPath"
}

### 5. elevate to admin
if (-not $IsAdmin) {
    Write-Host "Not running as administrator. Relaunching with elevation... "
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -VhdPath `"$VhdPath`""
    $psi.Verb = 'runas'
    try {
        [System.Diagnostics.Process]::Start($psi) | Out-Null
    } catch {
        Write-Error "Failed to relaunch as administrator. Aborting."
        exit 1
    }
    exit
}

### 6. unmount target drive if already mounted
if (Test-Path "$launchDriveLetter`:") {
    Write-Host "Drive $launchDriveLetter exists, unmounting..."
    mountvol "$launchDriveLetter`:" /D
    Write-Host "Drive $launchDriveLetter unmounted."
} else {
    Write-Host "Drive $launchDriveLetter does not exist, no need to unmount."
}

### 7. mount the vhd in ro or rw mode

# Mount the VHD
if ($readonly -eq '1' -or $readonly -eq 'true') {
    Write-Host "Mounting VHD in read-only mode..."
    $diskImage = Mount-DiskImage -ImagePath $VhdPath -Access ReadOnly -PassThru
} else {
    Write-Host "Mounting VHD in read-write mode..."
    $diskImage = Mount-DiskImage -ImagePath $VhdPath -PassThru
}

# Get the disk number
$diskNumber = ($diskImage | Get-DiskImage | Get-Disk).Number

# Get the partition (assuming only one partition, adjust if needed)
$partition = Get-Partition -DiskNumber $diskNumber | Where-Object { $_.Type -ne 'Reserved' } | Select-Object -First 1

# Assign the drive letter
if ($partition) {
    Write-Host "Assigning drive letter $launchDriveLetter to partition..."
    Set-Partition -DiskNumber $diskNumber -PartitionNumber $partition.PartitionNumber -NewDriveLetter $launchDriveLetter
    Write-Host "Drive letter $launchDriveLetter assigned."
} else {
    Write-Error "No valid partition found on the VHD."
    exit 1
}

### 8. mklink targetSaveDir to sourceSaveDir
if ($ini.ContainsKey('sourceSaveDir') -and $ini.ContainsKey('targetSaveDir')) {

    $sourceSaveDir = $ini['sourceSaveDir']
    $targetSaveDir = $ini['targetSaveDir']
    
    $sourceSaveDir = [Environment]::ExpandEnvironmentVariables($sourceSaveDir)
    $targetSaveDir = [Environment]::ExpandEnvironmentVariables($targetSaveDir)
    
    if (-not [System.IO.Path]::IsPathRooted($sourceSaveDir)) {
        $sourceSaveDir = "${launchDriveLetter}:\$sourceSaveDir"
    }

    if (-not (Test-Path $sourceSaveDir)) {
        Write-Host "sourceSaveDir $sourceSaveDir does not exist. Creating it..."
        New-Item -ItemType Directory -Path $sourceSaveDir | Out-Null
    }

    if (-not (Test-Path $targetSaveDir)) {
        $parentDir = Split-Path -Path $targetSaveDir -Parent
        if (-not (Test-Path $parentDir)) {
            Write-Host "Parent directory $parentDir does not exist. Creating it..."
            New-Item -ItemType Directory -Path $parentDir | Out-Null
        }
        Write-Host "Creating symlink: $targetSaveDir -> $sourceSaveDir"
        New-Item -ItemType SymbolicLink -Path $targetSaveDir -Target $sourceSaveDir
    } else {
        Write-Host "Symlink or directory already exists at $targetSaveDir, skipping mklink."
    }
}

### 9. check if launchPath exists
if (-not (Test-Path $launchPath)) {
    Write-Error "Error: launchPath does not exist after mounting: $launchPath"
    exit 1
} else {
    Write-Host "launchPath exists after mounting: $launchPath"
}

### 10. generate lnk file
function Extract-ExeIcon {
    param (
        [string]$ExePath,
        [string]$IcoPath
    )
    Add-Type -AssemblyName System.Drawing
    try {
        $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($ExePath)
        if ($icon) {
            $stream = New-Object System.IO.FileStream($IcoPath, [System.IO.FileMode]::Create)
            $icon.Save($stream)
            $stream.Close()
            return $true
        }
    } catch {
        Write-Host "Failed to extract icon: $_"
    }
    return $false
}

$WshShell = New-Object -ComObject WScript.Shell
$LnkPath = Join-Path -Path $VhdDir -ChildPath "start.lnk"
# If shortcut already exists, skip shortcut creation
if (Test-Path $LnkPath) {
    Write-Host "Shortcut $LnkPath already exists, skipping shortcut creation."
} else {
    $VhdFileName = [System.IO.Path]::GetFileName($VhdPath)
    $Shortcut = $WshShell.CreateShortcut($LnkPath)
    $Shortcut.TargetPath = "powershell.exe"
    $Shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File vhd-launcher.ps1 -VhdPath `"$VhdFileName`""
    $Shortcut.Description = "Portable link"
    $Shortcut.Save()
}

$DesktopPath = [Environment]::GetFolderPath('Desktop')
$DesktopLnkPath = Join-Path $DesktopPath ([System.IO.Path]::GetFileName($LnkPath))
if (Test-Path $DesktopLnkPath) {
    Write-Host "Shortcut $DesktopLnkPath already exists, skipping shortcut creation."
} else {
    $IconPath = $VhdPath -replace '\.vhd$', '.ico'
    $iconExtracted = Extract-ExeIcon -ExePath $launchPath -IcoPath $IconPath
    $DesktopShortcut = $WshShell.CreateShortcut($DesktopLnkPath)
    $DesktopShortcut.TargetPath = "powershell.exe"
    $DesktopShortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -VhdPath `"$VhdPath`""
    if ($iconExtracted -and (Test-Path $IconPath)) {
        $DesktopShortcut.IconLocation = $IconPath
    }
    $DesktopShortcut.Save()
}

### 11. I am admin here, Launch the game as non-admin user
Write-Host "Launching the game as non-admin user: $launchPath"
Start-Process -FilePath "explorer.exe" -ArgumentList "`"$launchPath`""
