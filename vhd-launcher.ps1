param(
    [Parameter(Mandatory = $false)]
    [string]$VhdPath,
    [Parameter(Mandatory = $false)]
    [ValidateSet('launch', 'add-desktop-shortcut', 'add-steam-shortcut', 'print-steam-shortcuts')]
    [string]$Action = 'launch'
)

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class Crc32Native {
    [DllImport("ntdll.dll")]
    public static extern uint RtlComputeCrc32(uint dwInitial, byte[] pData, int iLen);
}
"@

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

function Get-CurrentUserSteamRegistryKeyPath {
    return @("HKCU:\Software\Valve\Steam", "SteamPath")
}

function Get-LocalMachineSteamRegistryKeyPath {
    return @("HKLM:\SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath")
}

function Find-SteamDirectory {
    $steamRegistryPath = Get-CurrentUserSteamRegistryKeyPath
    $path = $steamRegistryPath[0]
    $key = $steamRegistryPath[1]

    if ((Test-Path -Path "$path") -and ($null -ne (Get-ItemProperty -Path "$path" -Name "$key" -ErrorAction SilentlyContinue)))
    {
        return Get-ItemProperty -Path "$path" -Name "$key" | Select-Object -ExpandProperty "$key"
    } else {
        $steamRegistryPath = Get-LocalMachineSteamRegistryKeyPath
        $path = $steamRegistryPath[0]
        $key = $steamRegistryPath[1]

        if ((Test-Path -Path "$path") -and ($null -ne (Get-ItemProperty -Path "$path" -Name "$key" -ErrorAction SilentlyContinue)))
        {
            return Get-ItemProperty -Path "$path" -Name "$key" | Select-Object -ExpandProperty "$key"
        } else {
            return $null
        }
    }
}

function Parse-VDFBuffer {  
    param(  
        [byte[]]$Buffer,  
        [hashtable]$Options = @{  
            autoConvertBooleans = $true  
            autoConvertArrays = $true  
            dateProperties = @('LastPlayTime')  
        }  
    )  
      
    # VDF type constants from constants.js  
    $VDF_TYPES = @{  
        object = 0x00  
        string = 0x01  
        int = 0x02  
    }  
      
    $VDF_SPECIAL = @{  
        objectEnd = 0x08  
        stringEnd = 0x00  
        propertyNameEnd = 0x00  
    }  
      
    # Parser context object  
    $context = @{  
        buffer = $Buffer  
        position = 0  
        options = $Options  
    }  
      
    function Test-IsNumber {  
        param($str)  
        return $str -match '^\d+$'  
    }  
      
    function Read-StringValue {  
        param($ctx)  
          
        $start = $ctx.position  
        while ($ctx.buffer[$ctx.position] -ne $VDF_SPECIAL.stringEnd) {  
            $ctx.position++  
        }  
          
        $length = $ctx.position - $start  
        $value = [System.Text.Encoding]::UTF8.GetString($ctx.buffer, $start, $length)  
        $ctx.position++ # Skip string terminator  
        return $value  
    }  
      
    function Read-IntValue {  
        param($ctx)  
          
        $value = [BitConverter]::ToInt32($ctx.buffer, $ctx.position)  
        $ctx.position += 4  
        return $value  
    }  
      
    function Read-ObjectValue {  
        param($ctx)  
          
        $obj = @{}  
          
        do {  
            $type = $ctx.buffer[$ctx.position]  
            $ctx.position++  
              
            # Handle empty objects/arrays  
            if ($type -eq $VDF_SPECIAL.objectEnd) {  
                break  
            }  
              
            $propName = Read-StringValue $ctx  
              
            try {  
                $val = $null  
                switch ($type) {  
                    $VDF_TYPES.object {  
                        $val = Read-ObjectValue $ctx  
                    }  
                    $VDF_TYPES.string {  
                        $val = Read-StringValue $ctx  
                    }  
                    $VDF_TYPES.int {  
                        $val = Read-IntValue $ctx  
                          
                        # Apply date conversion  
                        if ($ctx.options.dateProperties -contains $propName) {  
                            $val = [DateTimeOffset]::FromUnixTimeSeconds($val).DateTime  
                        }  
                        # Apply boolean conversion  
                        elseif ($ctx.options.autoConvertBooleans -and ($val -eq 1 -or $val -eq 0)) {  
                            $val = [bool]$val  
                        }  
                    }  
                }  
                $obj[$propName] = $val  
            }  
            catch {  
                throw "Error handling property: $propName - $_"  
            }  
              
        } while ($ctx.position -lt $ctx.buffer.Length)  
          
        return $obj  
    }  
      
    return Read-ObjectValue $context  
}  
  
function Parse-VDFFile {  
    param(  
        [string]$FilePath,  
        [hashtable]$Options = @{  
            autoConvertBooleans = $true  
            autoConvertArrays = $true  
            dateProperties = @('LastPlayTime')  
        }  
    )  
      
    if (-not (Test-Path $FilePath)) {  
        throw "File not found: $FilePath"  
    }  
      
    $buffer = [System.IO.File]::ReadAllBytes($FilePath)  
    return Parse-VDFBuffer -Buffer $buffer -Options $Options  
}

function Write-VDFBuffer {  
    param(  
        [object]$Object  
    )  
      
    # VDF type constants  
    $VDF_TYPES = @{  
        object = 0x00  
        string = 0x01  
        int = 0x02  
    }  
      
    $VDF_SPECIAL = @{  
        objectEnd = 0x08  
        stringEnd = 0x00  
        propertyNameEnd = 0x00  
    }  
      
    # Dynamic buffer management  
    $buffer = @{  
        data = [System.Collections.Generic.List[byte]]::new()  
        allocSize = 256  
    }  
      
    function Test-IsNumber {  
        param($value)  
        return ($value -is [int] -or $value -is [double] -or $value -is [float]) -and `
               -not [double]::IsNaN($value) -and `
               ([math]::Abs([double]$value) -ne [double]::Infinity)
    }  
      
    function Write-Value {  
        param($val, $buf)  
          
        # Pre-process values to align with writable values  
        if ($null -eq $val) {  
            $val = ''  
        }  
        elseif ($val -is [DateTime]) {  
            # Convert dates to Unix timestamps  
            $val = [int](($val - [DateTime]'1970-01-01').TotalSeconds)  
        }  
        elseif ($val -eq $true) {  
            $val = 1  
        }  
        elseif ($val -eq $false) {  
            $val = 0  
        }  
          
        # Write values based on type  
        if ($val -is [string]) {  
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($val)  
            $buf.data.AddRange($bytes)  
            $buf.data.Add($VDF_SPECIAL.stringEnd)  
        }  
        elseif (Test-IsNumber $val) {  
            # Write 32-bit little-endian integer  
            $bytes = [BitConverter]::GetBytes([int]$val)  
            if (-not [BitConverter]::IsLittleEndian) {  
                [Array]::Reverse($bytes)  
            }  
            $buf.data.AddRange($bytes)  
        }  
        elseif ($val -is [object]) {  
            # 不支持 array
            if ($val -is [array]) {
                throw "Writer does not support array type in VDF."
            }
            $keys = @()
            if ($val -is [hashtable]) {  
                $keys = $val.Keys  
            }  
            else {  
                $keys = $val.PSObject.Properties.Name  
            }  
            foreach ($key in $keys) {  
                $propValue = if ($val -is [hashtable]) { $val[$key] }  
                            else { $val.$key }  
                  
                # Determine VDF type constant  
                $constant = $null  
                if ($null -eq $propValue -or $propValue -is [string]) {  
                    $constant = $VDF_TYPES.string  
                }  
                elseif ($propValue -eq $true -or $propValue -eq $false -or   
                        (Test-IsNumber $propValue) -or $propValue -is [DateTime]) {  
                    $constant = $VDF_TYPES.int  
                }  
                elseif ($propValue -is [object]) {  
                    $constant = $VDF_TYPES.object  
                }  
                else {  
                    throw "Writer encountered unhandled value: $propValue"  
                }  
                  
                # Write type constant  
                $buf.data.Add($constant)  
                  
                # Write property name  
                $keyBytes = [System.Text.Encoding]::UTF8.GetBytes($key)  
                $buf.data.AddRange($keyBytes)  
                $buf.data.Add($VDF_SPECIAL.propertyNameEnd)  
                  
                # Recursively write property value  
                Write-Value $propValue $buf  
            }  
              
            # Write object end marker  
            $buf.data.Add($VDF_SPECIAL.objectEnd)  
        }  
        else {  
            throw "Writer encountered unhandled value: $val"  
        }  
    }  
      
    Write-Value $Object $buffer  
    return $buffer.data.ToArray()  
}  
  
function Write-VDFFile {  
    param(  
        [string]$FilePath,  
        [object]$Object  
    )  
      
    $buffer = Write-VDFBuffer -Object $Object  
    [System.IO.File]::WriteAllBytes($FilePath, $buffer)  
}

function Get-SteamShortcutsVdfPath {
    # Returns a hashtable with SteamDirectory, UserDir, ShortcutsVdfPath
    $steamDirectory = Find-SteamDirectory
    if (-not $steamDirectory) {
        Write-Error "Steam directory not found."
        return $null
    }

    $userdataPath = Join-Path $steamDirectory "userdata"
    if (-not (Test-Path $userdataPath)) {
        Write-Error "Steam userdata directory not found at $userdataPath"
        return $null
    }

    $userDirs = Get-ChildItem -Path $userdataPath -Directory
    if ($userDirs.Count -eq 0) {
        Write-Error "No user directories found in $userdataPath"
        return $null
    } elseif ($userDirs.Count -gt 1) {
        Write-Warning "Multiple user directories found. Using the first one: $($userDirs[0].Name)"
    }

    $userDir = $userDirs[0].FullName
    $shortcutsVdfPath = Join-Path $userDir "config\shortcuts.vdf"

    return @{ 
        SteamDirectory = $steamDirectory
        UserDir = $userDir
        ShortcutsVdfPath = $shortcutsVdfPath
    }
}

function Get-Crc32 {
    param([string]$InputString)
    $arr = [System.Text.Encoding]::UTF8.GetBytes($InputString)
    return [Crc32Native]::RtlComputeCrc32(0, $arr, $arr.Length)
}

function Get-SteamShortcutId {
    param(
        [string]$ExePath,
        [string]$AppName
    )
    $unique = "$ExePath$AppName"
    $crc32 = Get-Crc32 $unique
    $appid = $crc32 -bor 0x80000000
    if ($appid -gt [int]::MaxValue) {
        $appid = $appid - 0x100000000  # 2^32
    }
    return [int]$appid  # 保证类型为 System.Int32
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
    $vhdFiles = @(Get-ChildItem -Path $PWD -Filter *.vhd | Select-Object -ExpandProperty FullName)
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

$VhdDir = Split-Path -Path $VhdPath -Parent

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
$appName = if ($ini['appName']) {
    $ini['appName']
} else {
    [System.IO.Path]::GetFileNameWithoutExtension($VhdPath)
}

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

### 3.x other actions

if ($Action -eq 'add-desktop-shortcut') {
    $WshShell = New-Object -ComObject WScript.Shell
    $DesktopPath = [Environment]::GetFolderPath('Desktop')
    $shortcutFileName = "$appName.lnk"
    $DesktopLnkPath = Join-Path $DesktopPath $shortcutFileName
    if (Test-Path $DesktopLnkPath) {
        Write-Host "Shortcut $DesktopLnkPath already exists, skipping shortcut creation."
    } else {
        $IconPath = $VhdPath -replace '\.vhd$', '.ico'
        $DesktopShortcut = $WshShell.CreateShortcut($DesktopLnkPath)
        $DesktopShortcut.TargetPath = "powershell.exe"
        $DesktopShortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -VhdPath `"$VhdPath`""
        if ($IconPath -and (Test-Path $IconPath)) { $iconPath = $IconPath }
        $DesktopShortcut.IconLocation = $iconPath
        $DesktopShortcut.Save()
    }
    Write-Host "Action 'add-desktop-shortcut' completed."
    Stop-Transcript
    exit 0
} elseif ($Action -eq 'add-steam-shortcut') {
    $steamInfo = Get-SteamShortcutsVdfPath
    if (-not $steamInfo) {
        Stop-Transcript
        exit 1
    }
    $steamDirectory = $steamInfo.SteamDirectory
    $userDir = $steamInfo.UserDir
    $shortcutsVdfPath = $steamInfo.ShortcutsVdfPath

    if (Test-Path $shortcutsVdfPath) {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $backupPath = $shortcutsVdfPath + "." + $timestamp + ".backup"
        Copy-Item -Path $shortcutsVdfPath -Destination $backupPath -Force
        Write-Host "Created backup of shortcuts.vdf at: $backupPath"
    } else {
        Write-Host "shortcuts.vdf not found, will create a new one."
    }

    if (Test-Path $shortcutsVdfPath) {
        $shortcuts = Parse-VDFFile -FilePath $shortcutsVdfPath
    } else {
        $shortcuts = @{ shortcuts = @{} }
    }

    $IconPath = $VhdPath -replace '\.vhd$', '.ico'
    $exePath = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
    $appid = Get-SteamShortcutId -ExePath $exePath -AppName $appName
    $newShortcut = @{
        appid = $appid
        appname = $appName
        Exe = $exePath
        StartDir = $VhdDir
        icon = if ($IconPath -and (Test-Path $IconPath)) { $IconPath } else { "" }
        ShortcutPath = ""
        LaunchOptions = "-NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -VhdPath $VhdPath"
        IsHidden = $false
        AllowDesktopConfig = $true
        OpenVR = $false
        Devkit = $false
        DevkitGameID = ""
        DevkitOverrideAppID = $false
        AllowOverlay = $true
        FlatpakAppID = ""
        LastPlayTime = "/Date($([int]([DateTimeOffset]::Now.ToUnixTimeSeconds())))/"
        tags = @{}
    }

    # 追加新快捷方式
    # Find the next available key number for the shortcuts dictionary
    $nextKey = 0
    if ($shortcuts.shortcuts.Keys.Count -gt 0) {
        # Get the highest existing key number and add 1
        $existingKeys = [int[]]$shortcuts.shortcuts.Keys | Sort-Object
        $nextKey = $existingKeys[-1] + 1
    }

    $shortcuts.shortcuts["$nextKey"] = $newShortcut
    Write-VDFFile -FilePath $shortcutsVdfPath -Object $shortcuts
    Write-Host "Added Steam shortcut for: $appName"
    Stop-Transcript
    exit 0
} elseif ($Action -eq 'print-steam-shortcuts') {
    $steamInfo = Get-SteamShortcutsVdfPath
    if (-not $steamInfo) {
        Stop-Transcript
        exit 1
    }
    $steamDirectory = $steamInfo.SteamDirectory
    $userDir = $steamInfo.UserDir
    $shortcutsVdfPath = $steamInfo.ShortcutsVdfPath

    if (-not (Test-Path $shortcutsVdfPath)) {
        Write-Error "shortcuts.vdf not found at $shortcutsVdfPath"
        Stop-Transcript
        exit 1
    }
    Write-Host "shortcuts.vdf found at $shortcutsVdfPath"

    $shortcuts = Parse-VDFFile -FilePath $shortcutsVdfPath
    if (-not $shortcuts.shortcuts) {
        Write-Host "No shortcuts found in $shortcutsVdfPath"
        Stop-Transcript
        exit 0
    }

    $shortcuts | ConvertTo-Json -Depth 10
    Write-Host "Action 'print-steam-shortcuts' completed."
    Stop-Transcript
    exit 0
}

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

### 11. Launch the game
$ReadDiskLetter = $VhdPath.Substring(0, 1)
LaunchAndMonitor -LaunchPath $launchPath -DriveLetter $ReadDiskLetter