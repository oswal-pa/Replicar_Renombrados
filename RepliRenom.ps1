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

Write-Host "Leyendo archivos..." -ForegroundColor Cyan

$sourceFiles = @(Get-ChildItem -Path $sourceFolder -File -Recurse)
$destFiles = @(Get-ChildItem -Path $destinationFolder -File -Recurse)

Write-Host "Archivos origen: $($sourceFiles.Count)" -ForegroundColor Green
Write-Host "Archivos destino: $($destFiles.Count)" -ForegroundColor Red

# Crear índices por tamaño y nombre+tamaño
$destBySize = @{}
$destByNameSize = @{}

foreach ($file in $destFiles) {
    # Índice por tamaño
    $sizeKey = $file.Length
    if (-not $destBySize.ContainsKey($sizeKey)) {
        $destBySize[$sizeKey] = @()
    }
    $destBySize[$sizeKey] += $file
    
    # Índice por nombre+tamaño para búsqueda rápida
    $nameSizeKey = "$($file.Name)|$($file.Length)"
    $destByNameSize[$nameSizeKey] = $file
}

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
    
    # PASO 1: Comprobar si existe en destino con el mismo nombre y tamaño
    $nameSizeKey = "$($src.Name)|$($src.Length)"
    if ($destByNameSize.ContainsKey($nameSizeKey)) {
        $existingFile = $destByNameSize[$nameSizeKey]
        
        # Si ya existe con el mismo nombre y tamaño, saltar
        Write-Host "Existe: $($src.Name) [$([Math]::Round($src.Length/1MB, 2))MB]" -ForegroundColor DarkGray
        continue
    }
    
    # PASO 2: Si no existe, proceder a comparar por checksum
    # Cache del checksum origen usando solo tamaño (independiente de timestamps)
    $srcCacheKey = "$($src.FullName)|$($src.Length)"
    if ($checksumCache.ContainsKey($srcCacheKey)) {
        $srcChecksum = $checksumCache[$srcCacheKey]
    } else {
        Write-Host "Calculando checksum: $($src.Name) [$([Math]::Round($src.Length/1MB, 2))MB]" -ForegroundColor DarkGray
        $srcChecksum = Get-FileChecksum $src.FullName
        
        if ($null -eq $srcChecksum) {
            continue
        }
        
        $checksumCache[$srcCacheKey] = $srcChecksum
    }
    
    $encontrado = $false
    
    foreach ($dest in $candidates) {
        # Saltar si es el mismo archivo físico
        if ($dest.FullName -eq $src.FullName) {
            continue
        }
        
        # Saltar si ya existe con el mismo nombre (pero continuar con otros candidatos)
        if ($dest.Name -eq $src.Name) {
            continue
        }
        
        # Cache del checksum destino usando solo tamaño y ruta (sin timestamp)
        $destCacheKey = "$($dest.FullName)|$($dest.Length)"
        if ($checksumCache.ContainsKey($destCacheKey)) {
            $destChecksum = $checksumCache[$destCacheKey]
        } else {
            $destChecksum = Get-FileChecksum $dest.FullName
            
            if ($null -eq $destChecksum) {
                continue
            }
            
            $checksumCache[$destCacheKey] = $destChecksum
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
                    
                    # Actualizar índices
                    $destByNameSize["$($src.Name)|$($src.Length)"] = $dest
                    
                    $renombrados++
                    $encontrado = $true
                    break
                } catch {
                    Write-Error "✗ Error: $_"
                    $noCoinciden++
                }
            }
        }
    }
}

Write-Host "`n════════════════════════════════════" -ForegroundColor Cyan
Write-Host "Resumen:" -ForegroundColor Cyan
Write-Host "✓ Renombrados: $renombrados" -ForegroundColor Green
Write-Host "✗ Problemas: $noCoinciden" -ForegroundColor Red
Write-Host "════════════════════════════════════" -ForegroundColor Cyan
