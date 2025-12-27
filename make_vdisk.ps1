<#
.SYNOPSIS
    Script Universal para crear un Disco Virtual (VDI/VHD) desde una carpeta.
    Compatible con Windows 10/11.

.DESCRIPTION
    1. Calcula el tamaño del contenido de la carpeta actual.
    2. Crea un disco virtual contenedor (VHD).
    3. Copia todo el contenido dentro.
    4. Si VirtualBox está instalado, lo convierte a formato VDI (nativo/comprimido).
       Si no, deja el archivo en formato VHD (también compatible con VirtualBox).

.NOTES
    Requiere ejecutar como Administrador (solicitará permisos automáticamente).
    Autor: Antigravity Agent
#>

# --- Configuración Inicial ---
$SourceDir = $PSScriptRoot  # Carpeta donde está el script (y los archivos a copiar)
$OutputName = "contenido_proyecto"
$VBoxManagePath = "$env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe"

# --- 1. Auto-Elevación a Administrador ---
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "Este script necesita permisos de Administrador para crear y montar discos." -ForegroundColor Cyan
    Write-Host "Solicitando elevación..." -ForegroundColor Yellow
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

Clear-Host
Write-Host "=== Generador de Disco Virtual Universal ===" -ForegroundColor Cyan
Write-Host "Directorio Fuente: $SourceDir"
Write-Host "Detectando VirtualBox..."

# --- 2. Detección de VirtualBox ---
$CanConvertToVDI = $false
if (Test-Path $VBoxManagePath) {
    Write-Host "VirtualBox encontrado. Se creará un archivo .VDI optimizado." -ForegroundColor Green
    $CanConvertToVDI = $true
} else {
    # Intento de buscar en x86 por si acaso
    $VBoxManagePath = "${env:ProgramFiles(x86)}\Oracle\VirtualBox\VBoxManage.exe"
    if (Test-Path $VBoxManagePath) {
        Write-Host "VirtualBox encontrado (x86)." -ForegroundColor Green
        $CanConvertToVDI = $true
    } else {
        Write-Host "VirtualBox NO detectado. Se generará un archivo .VHD (compatible, pero menos optimizado)." -ForegroundColor Yellow
    }
}

# --- 3. Cálculo de Tamaño ---
Write-Host "Calculando tamaño de archivos... (esto puede tardar un poco)" -ForegroundColor Gray
# Excluir el propio script y posibles discos generados anteriormente para evitar bucles infinitos
$Excludes = @($MyInvocation.MyCommand.Name, "*.vdi", "*.vhd", "*.iso")
$Stats = Get-ChildItem -Path $SourceDir -Recurse -Exclude $Excludes -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum

if ($null -eq $Stats.Sum) {
    Write-Error "No se encontraron archivos en $SourceDir"
    Pause
    exit
}

$SizeInMB = [math]::Ceiling($Stats.Sum / 1MB)
# Añadir 20% de buffer + 500MB de seguridad para el sistema de archivos NTFS
$DiskSizeMB = [math]::Ceiling($SizeInMB * 1.2) + 500

Write-Host "Tamaño del contenido: $([math]::Round($SizeInMB/1024, 2)) GB" -ForegroundColor Gray
Write-Host "Tamaño del disco a crear: $([math]::Round($DiskSizeMB/1024, 2)) GB" -ForegroundColor White

# --- 4. Preparación de Rutas y Letra de Unidad ---
$VhdPath = Join-Path $SourceDir "$OutputName.vhd"
$VdiPath = Join-Path $SourceDir "$OutputName.vdi"

# Encontrar letra libre (Z hacia atrás)
$UsedLetters = Get-PSDrive -PSProvider FileSystem | Select-Object -ExpandProperty Name
$FreeLetter = 90..65 | ForEach-Object { [char]$_ } | Where-Object { $UsedLetters -notcontains $_ } | Select-Object -First 1

if (-not $FreeLetter) {
    Write-Error "No hay letras de unidad libres para montar el disco temporal."
    Pause
    exit
}
Write-Host "Usando letra temporal: ${FreeLetter}:" -ForegroundColor Gray

# Limpieza previa
if (Test-Path $VhdPath) { Remove-Item $VhdPath -Force }
if (Test-Path $VdiPath) { Remove-Item $VdiPath -Force }

# --- 5. Creación del VHD (DiskPart) ---
Write-Host "Creando y formateando disco virtual..." -ForegroundColor Cyan

$DiskPartCreateScript = @"
create vdisk file="$VhdPath" maximum=$DiskSizeMB type=expandable
select vdisk file="$VhdPath"
attach vdisk
create partition primary
format fs=ntfs quick label="ProjectDate"
assign letter=$FreeLetter
"@

$DiskPartCreateScript | diskpart | Out-Null

# Esperar a que el sistema monte la unidad
$Retries = 0
do {
    Start-Sleep -Seconds 2
    if (Test-Path "${FreeLetter}:\") { break }
    $Retries++
    Write-Host "Esperando montaje... ($Retries/10)"
} until ($Retries -ge 10)

if (-not (Test-Path "${FreeLetter}:\")) {
    Write-Error "Falló el montaje del disco. Inténtalo de nuevo."
    # Cleanup
    "select vdisk file=`"$VhdPath`"`ndetach vdisk" | diskpart | Out-Null
    Pause
    exit
}

# --- 6. Copia de Archivos (Robocopy) ---
Write-Host "Copiando archivos al disco virtual..." -ForegroundColor Cyan
Write-Host "Fuente: $SourceDir"
Write-Host "Destino: ${FreeLetter}:\"

# Robocopy es robusto y rápido. 
# /S (subcarpetas) /XD (excluir directorios) /XF (excluir archivos)
$RoboArgs = @($SourceDir, "${FreeLetter}:\", "*.*", "/S", "/MT:8", "/NFL", "/NDL", "/NJH", "/NJS")
# Exclusiones importantes: System Volume Info, Recycle Bin, el propio disco que estamos creando
$RoboExcludeDirs = @('$RECYCLE.BIN', 'System Volume Information')
$RoboExcludeFiles = @($MyInvocation.MyCommand.Name, "$OutputName.vhd", "$OutputName.vdi")

# Ejecutar robocopy (código de salida < 8 es éxito)
robocopy $SourceDir "${FreeLetter}:\" *.* /S /XD $RoboExcludeDirs /XF $RoboExcludeFiles /MT:8 /R:1 /W:1

Write-Host "Copia finalizada." -ForegroundColor Green

# --- 7. Desmontar VHD ---
Write-Host "Desmontando disco..." -ForegroundColor Cyan
$DiskPartDetachScript = @"
select vdisk file="$VhdPath"
detach vdisk
"@
$DiskPartDetachScript | diskpart | Out-Null

# --- 8. Conversión a VDI (Opcional) ---
if ($CanConvertToVDI) {
    Write-Host "Convirtiendo a formato VDI (VirtualBox Nativo)..." -ForegroundColor Cyan
    $Proc = Start-Process -FilePath $VBoxManagePath -ArgumentList "clonemedium disk `"$VhdPath`" `"$VdiPath`" --format VDI" -Wait -NoNewWindow -PassThru
    
    if ($Proc.ExitCode -eq 0) {
        Write-Host "Conversión Exitosa." -ForegroundColor Green
        Write-Host "Borrando archivo temporal VHD..."
        Remove-Item $VhdPath -Force
        Write-Host "¡LISTO! Tu disco está en: $VdiPath" -ForegroundColor Green
    } else {
        Write-Error "Hubo un error en la conversión. Conservando el archivo .vhd original."
        Write-Host "Tu disco está en: $VhdPath" -ForegroundColor Yellow
    }
} else {
    Write-Host "¡LISTO! (Sin conversión VDI). Tu disco está en: $VhdPath" -ForegroundColor Green
}

Write-Host "Presiona cualquier tecla para salir..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
