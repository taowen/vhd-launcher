param(
    [Parameter(Mandatory = $false)]
    [string]$VhdPath
)

function LaunchAndMonitor {
    param(
        [string]$LaunchPath,
        [string]$DriveLetter,
        [int]$MonitorDuration = 60,
        [int]$MonitorInterval = 3
    )
    
    Write-Host "Launching the game: $LaunchPath"
    $workingDir = Split-Path -Parent $LaunchPath
    $fileName = Split-Path -Leaf $LaunchPath
    Start-Process -FilePath $fileName -WorkingDirectory $workingDir

    ### Monitor disk performance
    $endTime = (Get-Date).AddSeconds($MonitorDuration)

    # Get the disk number for the drive letter
    $diskNumber = (Get-Partition -DriveLetter $DriveLetter).DiskNumber
    $DriveLetter = $DriveLetter + ":"

    while ((Get-Date) -lt $endTime) {
        try {
            $diskRead = Get-Counter "\PhysicalDisk($diskNumber $DriveLetter)\Disk Reads/sec" -ErrorAction Stop
            $diskReadBytes = Get-Counter "\PhysicalDisk($diskNumber $DriveLetter)\Disk Read Bytes/sec" -ErrorAction Stop
            
            $readsPerSec = [math]::Round($diskRead.CounterSamples.CookedValue, 2)
            $bytesPerSec = [math]::Round($diskReadBytes.CounterSamples.CookedValue / 1MB, 2)
            Write-Host "Drive $DriveLetter - Reads/sec: $readsPerSec, Read Speed: $bytesPerSec MB/s"
        } catch {
            Write-Host "Error accessing performance counters for drive $DriveLetter`: $_"
            Write-Host "Listing available PhysicalDisk counters:"
            Get-Counter -ListSet "PhysicalDisk" | Select-Object -ExpandProperty Counter | Where-Object { $_ -like "*$DriveLetter*" } | ForEach-Object {
                Write-Host "  $_"
            }
        }
        
        Start-Sleep -Seconds $MonitorInterval
    }
}

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

# If VhdPath is not provided, search for *.vhd in the current directory
if (-not $VhdPath -or $VhdPath -eq "") {
    $vhdFiles = Get-ChildItem -Path $PWD -Filter *.vhd | Select-Object -ExpandProperty FullName
    if ($vhdFiles.Count -eq 0) {
        Write-Error "Error: No VHD file found in the current directory. Please specify -VhdPath."
        exit 1
    } elseif ($vhdFiles.Count -eq 1) {
        $VhdPath = $vhdFiles[0]
        Write-Host "VhdPath not provided. Using found VHD: $VhdPath"
    } else {
        Write-Error "Error: Multiple VHD files found in the current directory. Please specify -VhdPath."
        $vhdFiles | ForEach-Object { Write-Host $_ }
        exit 1
    }
}

if (-not ([System.IO.Path]::IsPathRooted($VhdPath))) {
    $VhdPath = Join-Path -Path $PWD -ChildPath $VhdPath
}
if (-not (Test-Path $VhdPath)) {
    Write-Error "Error: VHD file not found at path: $VhdPath"
    Stop-Transcript
    exit 1
}

Write-Host "The resolved vhd file path is: $VhdPath"

### 3. read configuration
$IniPath = $VhdPath -replace '\.vhd$', '.ini'
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
    $ReadDiskLetter = $VhdPath.Substring(0, 1)
    LaunchAndMonitor -LaunchPath $launchPath -DriveLetter $ReadDiskLetter
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
    $unmountSuccess = $false
    $diskImageToUnmount = Get-DiskImage -DevicePath "\\.\${launchDriveLetter}:" -ErrorAction SilentlyContinue
    if ($diskImageToUnmount -and $diskImageToUnmount.ImagePath) {
        Write-Host "Dismounting VHD '$($diskImageToUnmount.ImagePath)' currently on $launchDriveLetter`:"
        Dismount-DiskImage -ImagePath $diskImageToUnmount.ImagePath -ErrorAction Stop
        $unmountSuccess = $true
        Write-Host "VHD dismounted successfully."
    } else {
        $partition = Get-Partition -DriveLetter $launchDriveLetter.ToCharArray()[0] -ErrorAction SilentlyContinue
        if ($partition) {
            Write-Host "Removing access path for partition on $launchDriveLetter`:"
            $parentDisk = Get-Disk -Partition $partition
            if ($parentDisk.StorageType -eq "VirtualHardDisk") {
                Write-Warning "$launchDriveLetter`: is a partition on a VHD. Removing its access path."
            }
            Remove-PartitionAccessPath -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber -AccessPath "${launchDriveLetter}:\" -ErrorAction Stop
            $unmountSuccess = $true
            Write-Host "Partition access path removed."
        } elseif (Test-Path -LiteralPath "${launchDriveLetter}:\") {
            Write-Host "Drive $launchDriveLetter`:\ exists but not as a known VHD or partition. Attempting mountvol /D."
            mountvol "${launchDriveLetter}:" /D
            $unmountSuccess = $true
            Write-Host "mountvol /D executed."
        } else {
            Write-Host "$launchDriveLetter`: does not seem to be in use. No unmount action taken."
            $unmountSuccess = $true
        }
    }
    if ($unmountSuccess) {
        Write-Host "Unmount/clear attempt for $launchDriveLetter`: complete. Waiting for system to catch up..."
        Start-Sleep -Seconds 3
    }
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

### 8. link patch files

# Determine patch folder path (next to VHD)
$VhdDir = Split-Path -Path $VhdPath -Parent
$PatchDir = Join-Path $VhdDir 'patch'

if (Test-Path $PatchDir) {
    Write-Host "Patch folder found: $PatchDir. Linking patch files..."
    # Recursively get all files in patch
    $patchFiles = Get-ChildItem -Path $PatchDir -Recurse -File
    foreach ($patchFile in $patchFiles) {
        # Compute relative path from patch dir
        $relativePath = $patchFile.FullName.Substring($PatchDir.Length).TrimStart('\','/')
        # Target path on mounted drive
        $targetPath = Join-Path "${launchDriveLetter}:\" $relativePath
        $targetDir = Split-Path -Path $targetPath -Parent
        # Ensure target directory exists
        if ($targetDir -and -not (Test-Path $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }
        # If symlink already exists, check if it points to the correct file
        if ((Test-Path $targetPath) -and ((Get-Item $targetPath).LinkType -eq 'SymbolicLink')) {
            $existingTarget = (Get-Item $targetPath).Target
            if ($existingTarget -eq $patchFile.FullName) {
                Write-Host "Symlink already exists at $targetPath and points to correct file, skipping."
                continue
            } else {
                Write-Host "Symlink at $targetPath points to $existingTarget, expected $($patchFile.FullName). Replacing."
                Remove-Item $targetPath -Force
            }
        } elseif ((Test-Path $targetPath) -and ((Get-Item $targetPath).LinkType -ne 'SymbolicLink')) {
            Remove-Item $targetPath -Force
        }
        # Create symlink
        Write-Host "Creating symlink: $targetPath -> $($patchFile.FullName)"
        New-Item -ItemType SymbolicLink -Path $targetPath -Target $patchFile.FullName | Out-Null
    }
} else {
    Write-Host "No patch folder found at $PatchDir. Skipping patch linking."
}

### 9. mklink targetSaveDir to sourceSaveDir
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

### 10. check if launchPath exists
if (-not (Test-Path $launchPath)) {
    Write-Error "Error: launchPath does not exist after mounting: $launchPath"
    exit 1
} else {
    Write-Host "launchPath exists after mounting: $launchPath"
}

### 11. generate lnk file
$WshShell = New-Object -ComObject WScript.Shell
$VhdDir = Split-Path -Path $VhdPath -Parent
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
$DesktopLnkPath = $VhdPath -replace '\.vhd$', '.lnk'
$DesktopLnkPath = Join-Path $DesktopPath ([System.IO.Path]::GetFileName($DesktopLnkPath))
if (Test-Path $DesktopLnkPath) {
    Write-Host "Shortcut $DesktopLnkPath already exists, skipping shortcut creation."
} else {
    $IconPath = $VhdPath -replace '\.vhd$', '.ico'
    $DesktopShortcut = $WshShell.CreateShortcut($DesktopLnkPath)
    $DesktopShortcut.TargetPath = "powershell.exe"
    $DesktopShortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -VhdPath `"$VhdPath`""
    if (Test-Path $IconPath) {
        $DesktopShortcut.IconLocation = $IconPath
    }
    $DesktopShortcut.Save()
}

### 12. Launch the game
$ReadDiskLetter = $VhdPath.Substring(0, 1)
LaunchAndMonitor -LaunchPath $launchPath -DriveLetter $ReadDiskLetter