# Virtual Disk Creator (VDI/VHD)

Automated PowerShell utility to package the contents of a local directory into a virtual disk image compatible with VirtualBox (VDI) and Hyper-V (VHD).

This tool is designed to simplify the process of importing project files, backups, or raw data into a Virtual Machine without complex network setups or manual ISO creation.

## 🚀 Features

- **Automated Size Calculation**: Dynamically calculates the required disk size based on the folder contents plus a safety buffer.
- **Universal Compatibility**: 
  - If VirtualBox is installed, it creates an optimized `.vdi` file.
  - If VirtualBox is *not* installed, it falls back to a standard `.vhd` file (which is also compatible with VirtualBox).
- **Auto-Elevation**: Automatically requests Administrator privileges if not already running with them (required for mounting virtual disks).
- **Robust Copying**: Uses generic Windows mounting and `Robocopy` for reliable file transfer.
- **Self-Contained**: No external dependencies other than Windows 10/11 built-in tools.

## 📋 Prerequisites

- **OS**: Windows 10 or Windows 11.
- **PowerShell**: Version 5.1 or later (default on Windows).
- **VirtualBox** (Optional): Required if you want the native `.vdi` format. Without it, you get a `.vhd`.

## 🛠️ Usage

1. **Place the script**: Put the `make_vdisk.ps1` file inside the folder you want to convert into a disk.
2. **Run it**:
   - Right-click on `make_vdisk.ps1`.
   - Select **"Run with PowerShell"**.
   - Accepts the User Account Control (UAC) prompt to allow Administrator access.
3. **Wait**:
   - The script will calculate size, create a temporary VHD, mount it, copy files, and convert the image.
   - Once finished, you will see a `contenido_proyecto.vdi` (or `.vhd`) in the same folder.

## 📥 Importing into VirtualBox

1. Open VirtualBox and select your Virtual Machine.
2. Go to **Settings > Storage**.
3. Under the Controller (SATA/IDE), click the **"Add Hard Disk"** icon.
4. Click **Add** and select the generated file (`contenido_proyecto.vdi`).
5. Boot your VM. The disk will appear as a secondary drive allowing you to access all your files.

## 📝 Technical Details

The script performs the following steps:
1. **Source Analysis**: Scans the current directory to calculate the total size of files to copy.
2. **VHD Creation**: Uses Windows `diskpart` to create and mount a temporary `.vhd` file formatted as NTFS.
3. **Data Transfer**: Uses multi-threaded `robocopy` to mirror the directory structure into the virtual disk.
4. **Conversion via VBoxManage**: If available, it invokes the VirtualBox CLI tool to clone the VHD into a compressed VDI format.
5. **Cleanup**: Unmounts the disk and removes temporary artifacts.

## ⚠️ Disclaimer

This script manipulates virtual disk partitions. While it is designed to work safely within a containerized virtual file, always ensure you have backups of critical data before running disk management tools.
