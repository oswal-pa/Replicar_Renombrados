# Configuración
$sourceFolder = "C:\Ruta\De\Carpeta1"
$destinationFolder = "C:\Ruta\De\Carpeta2"
$bufferSize = 65536  # 64KB buffer para lectura óptima en discos mecánicos

# Validar que las carpetas existen
if (-not (Test-Path $sourceFolder)) {
    Write-Error "La carpeta de origen no existe: $sourceFolder"
    exit 1
}

if (-not (Test-Path $destinationFolder)) {
    Write-Error "La carpeta de destino no existe: $destinationFolder"
    exit 1
}

# Función de checksum optimizada para discos mecánicos
function Get-FileChecksum {
    param([string]$filePath)
    
    try {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $fileStream = [System.IO.File]::OpenRead($filePath)
        
        # Leer en bloques de 64KB (óptimo para discos mecánicos)
        $buffer = New-Object byte[] $bufferSize
        $bytesRead = 0
        
        while (($bytesRead = $fileStream.Read($buffer, 0, $bufferSize)) -gt 0) {
            $sha256.TransformBlock($buffer, 0, $bytesRead, $null, 0) | Out-Null
        }
        
        $sha256.TransformFinalBlock($buffer, 0, 0) | Out-Null
        $checksum = $sha256.Hash
        
        $fileStream.Close()
        $sha256.Dispose()
        
        return -join ($checksum | ForEach-Object { "{0:x2}" -f $_ })
    }
    catch {
        Write-Error "Error en $filePath : $_"
        return $null
    }
}

# Usar GetFilesBySize para comparación inicial más rápida
function Compare-FilesOptimized {
    param(
        [object[]]$sourceFiles,
        [object[]]$destFiles
    )
    
    # Agrupar por tamaño
    $destBySize = @{}
    foreach ($file in $destFiles) {
        $key = $file.Length
        if (-not $destBySize.ContainsKey($key)) {
            $destBySize[$key] = @()
        }
        $destBySize[$key] += $file
    }
    
    return $destBySize
}

Write-Host "Leyendo archivos..." -ForegroundColor Cyan

$sourceFiles = @(Get-ChildItem -Path $sourceFolder -File -Recurse)
$destFiles = @(Get-ChildItem -Path $destinationFolder -File -Recurse)

Write-Host "Archivos origen: $($sourceFiles.Count)" -ForegroundColor Green
Write-Host "Archivos destino: $($destFiles.Count)" -ForegroundColor Green

# Crear mapa de destinos por tamaño
$destBySize = Compare-FilesOptimized -sourceFiles $sourceFiles -destFiles $destFiles

$renombrados = 0
$noCoinciden = 0
$checksumCache = @{}

# Procesar por orden de tamaño (archivos pequeños primero para verificación rápida)
$sortedSource = $sourceFiles | Sort-Object -Property Length

foreach ($src in $sortedSource) {
    $candidates = $destBySize[$src.Length]
    
    if (-not $candidates) {
        continue
    }
    
    # Cache del checksum origen
    $srcKey = "$($src.FullName)|$($src.Length)|$($src.LastWriteTime)"
    if ($checksumCache.ContainsKey($srcKey)) {
        $srcChecksum = $checksumCache[$srcKey]
    } else {
        Write-Host "Calculando checksum: $($src.Name) [$([Math]::Round($src.Length/1MB, 2))MB]" -ForegroundColor DarkGray
        $srcChecksum = Get-FileChecksum $src.FullName
        
        if ($null -eq $srcChecksum) {
            continue
        }
        
        $checksumCache[$srcKey] = $srcChecksum
    }
    
    foreach ($dest in $candidates) {
        if ($dest.Name -eq $src.Name) {
            break
        }
        
        # Cache del checksum destino
        $destKey = "$($dest.FullName)|$($dest.Length)|$($dest.LastWriteTime)"
        if ($checksumCache.ContainsKey($destKey)) {
            $destChecksum = $checksumCache[$destKey]
        } else {
            $destChecksum = Get-FileChecksum $dest.FullName
            
            if ($null -eq $destChecksum) {
                continue
            }
            
            $checksumCache[$destKey] = $destChecksum
        }
        
        if ($srcChecksum -eq $destChecksum) {
            $newPath = Join-Path -Path $dest.DirectoryName -ChildPath $src.Name
            
            if (Test-Path $newPath) {
                Write-Warning "Existe: $newPath"
                $noCoinciden++
            } else {
                try {
                    Write-Host "✓ Renombrando: $($dest.Name) → $($src.Name)" -ForegroundColor Green
                    Rename-Item -Path $dest.FullName -NewName $src.Name -Force -ErrorAction Stop
                    $renombrados++
                } catch {
                    Write-Error "✗ Error: $_"
                    $noCoinciden++
                }
            }
            break
        }
    }
}

Write-Host "`n════════════════════════════════════" -ForegroundColor Cyan
Write-Host "Resumen:" -ForegroundColor Cyan
Write-Host "✓ Renombrados: $renombrados" -ForegroundColor Green
Write-Host "✗ Problemas: $noCoinciden" -ForegroundColor Red
Write-Host "════════════════════════════════════" -ForegroundColor Cyan
