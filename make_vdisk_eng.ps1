<#
.SYNOPSIS
    Universal Script to create a Virtual Disk (VDI/VHD) from a folder.
    Compatible with Windows 10/11.

.DESCRIPTION
    1. Calculates the size of the content in the current folder.
    2. Creates a virtual disk container (VHD).
    3. Copies all content into it.
    4. If VirtualBox is installed, it converts it to VDI format (native/compressed).
       Otherwise, it leaves the file in VHD format (also compatible with VirtualBox).

.NOTES
    Requires Administrator privileges (will automatically request elevation).
#>

# --- Initial Configuration ---
$SourceDir = $PSScriptRoot  # Folder where the script is located (and files to copy)
$OutputName = "project_content"
$VBoxManagePath = "$env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe"

# --- 1. Admin Auto-Elevation ---
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "This script needs Administrator privileges to create and mount disks." -ForegroundColor Cyan
    Write-Host "Requesting elevation..." -ForegroundColor Yellow
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

Clear-Host
Write-Host "=== Universal Virtual Disk Generator ===" -ForegroundColor Cyan
Write-Host "Source Directory: $SourceDir"
Write-Host "Detecting VirtualBox..."

# --- 2. VirtualBox Detection ---
$CanConvertToVDI = $false
if (Test-Path $VBoxManagePath) {
    Write-Host "VirtualBox found. An optimized .VDI file will be created." -ForegroundColor Green
    $CanConvertToVDI = $true
} else {
    # Attempt to find in x86 folder just in case
    $VBoxManagePath = "${env:ProgramFiles(x86)}\Oracle\VirtualBox\VBoxManage.exe"
    if (Test-Path $VBoxManagePath) {
        Write-Host "VirtualBox found (x86)." -ForegroundColor Green
        $CanConvertToVDI = $true
    } else {
        Write-Host "VirtualBox NOT detected. A .VHD file will be generated (compatible, but less optimized)." -ForegroundColor Yellow
    }
}

# --- 3. Size Calculation ---
Write-Host "Calculating file sizes... (this may take a while)" -ForegroundColor Gray
# Exclude the script itself and any previously generated disks to avoid infinite loops
$Excludes = @($MyInvocation.MyCommand.Name, "*.vdi", "*.vhd", "*.iso")
$Stats = Get-ChildItem -Path $SourceDir -Recurse -Exclude $Excludes -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum

if ($null -eq $Stats.Sum) {
    Write-Error "No files found in $SourceDir"
    Pause
    exit
}

$SizeInMB = [math]::Ceiling($Stats.Sum / 1MB)
# Add 20% buffer + 500MB security for NTFS filesystem
$DiskSizeMB = [math]::Ceiling($SizeInMB * 1.2) + 500

Write-Host "Content size: $([math]::Round($SizeInMB/1024, 2)) GB" -ForegroundColor Gray
Write-Host "Disk size to create: $([math]::Round($DiskSizeMB/1024, 2)) GB" -ForegroundColor White

# --- 4. Paths and Drive Letter Preparation ---
$VhdPath = Join-Path $SourceDir "$OutputName.vhd"
$VdiPath = Join-Path $SourceDir "$OutputName.vdi"

# Find a free drive letter (Z backwards)
$UsedLetters = Get-PSDrive -PSProvider FileSystem | Select-Object -ExpandProperty Name
$FreeLetter = 90..65 | ForEach-Object { [char]$_ } | Where-Object { $UsedLetters -notcontains $_ } | Select-Object -First 1

if (-not $FreeLetter) {
    Write-Error "No free drive letters available to mount the temporary disk."
    Pause
    exit
}
Write-Host "Using temporary drive letter: ${FreeLetter}:" -ForegroundColor Gray

# Previous cleanup
if (Test-Path $VhdPath) { Remove-Item $VhdPath -Force }
if (Test-Path $VdiPath) { Remove-Item $VdiPath -Force }

# --- 5. VHD Creation (DiskPart) ---
Write-Host "Creating and formatting virtual disk..." -ForegroundColor Cyan

$DiskPartCreateScript = @"
create vdisk file="$VhdPath" maximum=$DiskSizeMB type=expandable
select vdisk file="$VhdPath"
attach vdisk
create partition primary
format fs=ntfs quick label="ProjectData"
assign letter=$FreeLetter
"@

$DiskPartCreateScript | diskpart | Out-Null

# Wait for system to mount the drive
$Retries = 0
do {
    Start-Sleep -Seconds 2
    if (Test-Path "${FreeLetter}:\") { break }
    $Retries++
    Write-Host "Waiting for mount... ($Retries/10)"
} until ($Retries -ge 10)

if (-not (Test-Path "${FreeLetter}:\")) {
    Write-Error "Disk mount failed. Please try again."
    # Cleanup
    "select vdisk file=`"$VhdPath`"`ndetach vdisk" | diskpart | Out-Null
    Pause
    exit
}

# --- 6. File Copying (Robocopy) ---
Write-Host "Copying files to virtual disk..." -ForegroundColor Cyan
Write-Host "Source: $SourceDir"
Write-Host "Destination: ${FreeLetter}:\"

# Robocopy is robust and fast. 
# /S (subdirectories) /XD (exclude directories) /XF (exclude files)
$RoboArgs = @($SourceDir, "${FreeLetter}:\", "*.*", "/S", "/MT:8", "/NFL", "/NDL", "/NJH", "/NJS")
# Important exclusions: System Volume Info, Recycle Bin, and the disks we are creating
$RoboExcludeDirs = @('$RECYCLE.BIN', 'System Volume Information')
$RoboExcludeFiles = @($MyInvocation.MyCommand.Name, "$OutputName.vhd", "$OutputName.vdi")

# Execute robocopy (exit code < 8 is success)
robocopy $SourceDir "${FreeLetter}:\" *.* /S /XD $RoboExcludeDirs /XF $RoboExcludeFiles /MT:8 /R:1 /W:1

Write-Host "Copy completed." -ForegroundColor Green

# --- 7. Detach VHD ---
Write-Host "Detaching disk..." -ForegroundColor Cyan
$DiskPartDetachScript = @"
select vdisk file="$VhdPath"
detach vdisk
"@
$DiskPartDetachScript | diskpart | Out-Null

# --- 8. VDI Conversion (Optional) ---
if ($CanConvertToVDI) {
    Write-Host "Converting to VDI format (VirtualBox Native)..." -ForegroundColor Cyan
    $Proc = Start-Process -FilePath $VBoxManagePath -ArgumentList "clonemedium disk `"$VhdPath`" `"$VdiPath`" --format VDI" -Wait -NoNewWindow -PassThru
    
    if ($Proc.ExitCode -eq 0) {
        Write-Host "Conversion Successful." -ForegroundColor Green
        Write-Host "Deleting temporary VHD file..."
        Remove-Item $VhdPath -Force
        Write-Host "DONE! Your disk is at: $VdiPath" -ForegroundColor Green
    } else {
        Write-Error "There was an error during conversion. Keeping the original .vhd file."
        Write-Host "Your disk is at: $VhdPath" -ForegroundColor Yellow
    }
} else {
    Write-Host "DONE! (No VDI conversion). Your disk is at: $VhdPath" -ForegroundColor Green
}

Write-Host "Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

