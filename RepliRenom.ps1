# Configuración
$sourceFolder = "C:\Ruta\De\Carpeta1"
$destinationFolder = "C:\Ruta\De\Carpeta2"
$batchSize = 1000    # Procesar archivos en lotes de 1000
$maxPathLength = 260 # Límite de Windows para rutas (260 caracteres)
$bufferSize = 65536  # 64KB buffer para lectura óptima en discos mecánicos

# Validar versión de PowerShell
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Warning "PowerShell 7+ recomendado para mejor rendimiento. Usando TransformBlock."
    $useIncrementalHash = $false
} else {
    $useIncrementalHash = $true
}

# Validar que las carpetas existen
if (-not (Test-Path $sourceFolder)) {
    Write-Error "La carpeta de origen no existe: $sourceFolder"
    exit 1
}

if (-not (Test-Path $destinationFolder)) {
    Write-Error "La carpeta de destino no existe: $destinationFolder"
    exit 1
}

# Función para detectar enlaces simbólicos y hardlinks
function Test-IsSymbolicLink {
    param([string]$filePath)
    
    try {
        $file = Get-Item -Path $filePath -Force -ErrorAction Stop
        return $file.LinkType -eq 'SymbolicLink'
    } catch {
        return $false
    }
}

function Get-HardLinkCount {
    param([string]$filePath)
    
    try {
        $file = Get-Item -Path $filePath -Force -ErrorAction Stop
        return $file.HardLinkCount
    } catch {
        return 1
    }
}

# Función para detectar rutas largas
function Test-PathLength {
    param([string]$filePath)
    
    if ($filePath.Length -gt $maxPathLength) {
        return $false
    }
    return $true
}

# Función para verificar permisos de lectura
function Test-ReadPermission {
    param([string]$filePath)
    
    try {
        $fileStream = [System.IO.File]::OpenRead($filePath)
        $fileStream.Close()
        $fileStream.Dispose()
        return $true
    } catch {
        return $false
    }
}

# Función para verificar permisos de escritura en directorio
function Test-WritePermission {
    param([string]$directoryPath)
    
    try {
        $testFile = Join-Path -Path $directoryPath -ChildPath ".write-test-$([System.IO.Path]::GetRandomFileName())"
        [System.IO.File]::WriteAllText($testFile, "test")
        Remove-Item -Path $testFile -Force -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

# Función de checksum optimizada con manejo de errores
function Get-FileChecksum {
    param([string]$filePath)
    
    $fileStream = $null
    $hash = $null
    $sha256 = $null
    
    try {
        # Verificar permisos antes de intentar lectura
        if (-not (Test-ReadPermission $filePath)) {
            Write-Warning "Sin permisos de lectura: $filePath"
            return $null
        }
        
        $fileStream = [System.IO.File]::OpenRead($filePath)
        
        if ($useIncrementalHash) {
            $hash = [System.Security.Cryptography.IncrementalHash]::CreateHash(
                [System.Security.Cryptography.HashAlgorithmName]::SHA256
            )
            
            $buffer = New-Object byte[] $bufferSize
            $bytesRead = 0
            
            while (($bytesRead = $fileStream.Read($buffer, 0, $bufferSize)) -gt 0) {
                $hash.AppendData($buffer, 0, $bytesRead)
            }
            
            $checksum = $hash.GetHashAndReset()
        } else {
            $sha256 = [System.Security.Cryptography.SHA256]::Create()
            $buffer = New-Object byte[] $bufferSize
            $bytesRead = 0
            
            while (($bytesRead = $fileStream.Read($buffer, 0, $bufferSize)) -gt 0) {
                $sha256.TransformBlock($buffer, 0, $bytesRead, $null, 0) | Out-Null
            }
            
            $sha256.TransformFinalBlock($buffer, 0, 0) | Out-Null
            $checksum = $sha256.Hash
        }
        
        return -join ($checksum | ForEach-Object { "{0:x2}" -f $_ })
    }
    catch [System.UnauthorizedAccessException] {
        Write-Warning "Acceso denegado al archivo: $filePath"
        return $null
    }
    catch [System.IO.FileNotFoundException] {
        Write-Warning "Archivo no encontrado: $filePath"
        return $null
    }
    catch [System.IO.IOException] {
        Write-Warning "Error de I/O en archivo: $filePath - $_"
        return $null
    }
    catch {
        Write-Error "Error inesperado en $filePath : $_"
        return $null
    }
    finally {
        if ($fileStream) {
            try { $fileStream.Close(); $fileStream.Dispose() } catch { }
        }
        if ($hash) {
            try { $hash.Dispose() } catch { }
        }
        if ($sha256) {
            try { $sha256.Dispose() } catch { }
        }
    }
}

# Función auxiliar para procesar lotes
function Procesar-Lote {
    param(
        [object[]]$batch,
        [hashtable]$destBySize,
        [hashtable]$destByNameSize,
        [hashtable]$checksumCache,
        [hashtable]$processedDestPaths,
        [ref]$renombrados,
        [ref]$noCoinciden,
        [ref]$errorLog
    )
    
    foreach ($src in $batch) {
        $candidates = $destBySize[$src.Length]
        
        if (-not $candidates) {
            continue
        }
        
        $nameSizeKey = "$($src.Name)|$($src.Length)"
        if ($destByNameSize.ContainsKey($nameSizeKey)) {
            Write-Host "Existe: $($src.Name) [$([Math]::Round($src.Length/1MB, 2))MB]" -ForegroundColor DarkGray
            continue
        }
        
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
        
        $candidateIndex = 0
        foreach ($destMeta in $candidates) {
            if ($processedDestPaths.ContainsKey($destMeta.FullPath)) {
                $candidateIndex++
                continue
            }
            
            if ($destMeta.FullPath -eq $src.FullName) {
                $candidateIndex++
                continue
            }
            
            if ($destMeta.Name -eq $src.Name) {
                $candidateIndex++
                continue
            }
            
            $destCacheKey = "$($destMeta.FullPath)|$($destMeta.Length)"
            if ($checksumCache.ContainsKey($destCacheKey)) {
                $destChecksum = $checksumCache[$destCacheKey]
            } else {
                $destChecksum = Get-FileChecksum $destMeta.FullPath
                
                if ($null -eq $destChecksum) {
                    $candidateIndex++
                    continue
                }
                
                $checksumCache[$destCacheKey] = $destChecksum
            }
            
            if ($srcChecksum -eq $destChecksum) {
                $newPath = Join-Path -Path (Split-Path -Path $destMeta.FullPath) -ChildPath $src.Name
                
                # Verificar longitud de nueva ruta
                if (-not (Test-PathLength $newPath)) {
                    Write-Warning "Nueva ruta demasiado larga: $newPath"
                    $noCoinciden.Value++
                    $errorLog.Value += "Nueva ruta larga: $newPath"
                    $candidateIndex++
                    continue
                }
                
                if (Test-Path $newPath) {
                    Write-Warning "Existe: $newPath"
                    $noCoinciden.Value++
                    $candidateIndex++
                    continue
                }
                
                # Verificar permisos de escritura
                $parentDir = Split-Path -Path $destMeta.FullPath
                if (-not (Test-WritePermission $parentDir)) {
                    Write-Warning "Sin permisos de escritura en: $parentDir"
                    $noCoinciden.Value++
                    $errorLog.Value += "Sin permisos de escritura: $parentDir"
                    $candidateIndex++
                    continue
                }
                
                try {
                    Write-Host "✓ Renombrando: $($destMeta.Name) -> $($src.Name)" -ForegroundColor Green
                    Rename-Item -Path $destMeta.FullPath -NewName $src.Name -Force -ErrorAction Stop
                    
                    $oldFullPath = $destMeta.FullPath
                    $processedDestPaths[$oldFullPath] = $true
                    
                    $oldNameSizeKey = "$($destMeta.Name)|$($destMeta.Length)"
                    if ($destByNameSize.ContainsKey($oldNameSizeKey)) {
                        $destByNameSize.Remove($oldNameSizeKey)
                    }
                    
                    $destByNameSize[$nameSizeKey] = @{
                        FullPath = $newPath
                        Name = $src.Name
                        Length = $src.Length
                    }
                    
                    $candidates[$candidateIndex] = @{
                        FullPath = $newPath
                        Name = $src.Name
                        Length = $src.Length
                    }
                    
                    $checksumCache.Remove($destCacheKey)
                    $newCacheKey = "$($newPath)|$($src.Length)"
                    $checksumCache[$newCacheKey] = $destChecksum
                    
                    $renombrados.Value++
                    break
                } catch [System.UnauthorizedAccessException] {
                    Write-Error "✗ Acceso denegado al renombrar: $($destMeta.FullPath)"
                    $noCoinciden.Value++
                    $errorLog.Value += "Acceso denegado: $($destMeta.FullPath)"
                } catch [System.IO.IOException] {
                    Write-Error "✗ Error de I/O al renombrar: $($destMeta.FullPath) - $_"
                    $noCoinciden.Value++
                    $errorLog.Value += "Error I/O: $($destMeta.FullPath)"
                } catch {
                    Write-Error "✗ Error: $_"
                    $noCoinciden.Value++
                    $errorLog.Value += "Error renombrado: $($destMeta.FullPath) - $_"
                }
            }
            
            $candidateIndex++
        }
    }
}

Write-Host "PowerShell versión: $($PSVersionTable.PSVersion)" -ForegroundColor Cyan
Write-Host "Usando: $(if ($useIncrementalHash) { "IncrementalHash" } else { "TransformBlock" })" -ForegroundColor Yellow
Write-Host "Leyendo archivos en streaming..." -ForegroundColor Cyan

$destBySize = @{}
$destByNameSize = @{}
$processedDestPaths = @{}

$totalSourceFiles = 0
$skippedSource = 0
$renombrados = 0
$noCoinciden = 0
$checksumCache = @{}

$errorLog = @()

# PASO 1: Construir índice de destino en streaming con validación
Write-Host "Indexando carpeta destino..." -ForegroundColor Cyan

$skippedDest = 0
Get-ChildItem -Path $destinationFolder -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    $file = $_
    
    try {
        # Detectar y saltar enlaces simbólicos
        if (Test-IsSymbolicLink $file.FullName) {
            Write-Warning "Saltando enlace simbólico: $($file.FullName)"
            $skippedDest++
            return
        }
        
        # Detectar y saltar hardlinks (evita duplicación de checksums)
        $hardLinkCount = Get-HardLinkCount $file.FullName
        if ($hardLinkCount -gt 1) {
            Write-Warning "Saltando hardlink ($hardLinkCount enlaces): $($file.FullName)"
            $skippedDest++
            return
        }
        
        # Verificar longitud de ruta
        if (-not (Test-PathLength $file.FullName)) {
            Write-Warning "Ruta demasiado larga (>$maxPathLength caracteres): $($file.FullName)"
            $skippedDest++
            $errorLog += "Ruta larga: $($file.FullName)"
            return
        }
        
        # Verificar permisos de lectura
        if (-not (Test-ReadPermission $file.FullName)) {
            Write-Warning "Sin permisos de lectura: $($file.FullName)"
            $skippedDest++
            $errorLog += "Sin permisos: $($file.FullName)"
            return
        }
        
        $sizeKey = $file.Length
        
        if (-not $destBySize.ContainsKey($sizeKey)) {
            $destBySize[$sizeKey] = @()
        }
        
        $destBySize[$sizeKey] += @{
            FullPath = $file.FullName
            Name = $file.Name
            Length = $file.Length
        }
        
        $nameSizeKey = "$($file.Name)|$($file.Length)"
        $destByNameSize[$nameSizeKey] = @{
            FullPath = $file.FullName
            Name = $file.Name
            Length = $file.Length
        }
    }
    catch {
        Write-Warning "Error procesando archivo de destino: $($file.FullName) - $_"
        $skippedDest++
        $errorLog += "Error destino: $($file.FullName) - $_"
    }
}

$totalDestFiles = @($destBySize.Values | ForEach-Object { $_.Count } | Measure-Object -Sum | Select-Object -ExpandProperty Sum)
Write-Host "Destino indexado. Archivos: $totalDestFiles, Saltados: $skippedDest" -ForegroundColor Green

# PASO 2: Procesar archivos origen en lotes
Write-Host "Procesando archivos origen en lotes de $batchSize..." -ForegroundColor Cyan

$batch = @()
$batchNumber = 0

Get-ChildItem -Path $sourceFolder -File -Recurse -ErrorAction SilentlyContinue | Sort-Object -Property Length | ForEach-Object {
    try {
        $file = $_
        
        # Detectar y saltar enlaces simbólicos
        if (Test-IsSymbolicLink $file.FullName) {
            Write-Warning "Saltando enlace simbólico: $($file.FullName)"
            $skippedSource++
            return
        }
        
        # Detectar y saltar hardlinks
        $hardLinkCount = Get-HardLinkCount $file.FullName
        if ($hardLinkCount -gt 1) {
            Write-Warning "Saltando hardlink ($hardLinkCount enlaces): $($file.FullName)"
            $skippedSource++
            return
        }
        
        # Verificar longitud de ruta
        if (-not (Test-PathLength $file.FullName)) {
            Write-Warning "Ruta demasiado larga (>$maxPathLength caracteres): $($file.FullName)"
            $skippedSource++
            $errorLog += "Ruta larga: $($file.FullName)"
            return
        }
        
        # Verificar permisos de lectura
        if (-not (Test-ReadPermission $file.FullName)) {
            Write-Warning "Sin permisos de lectura: $($file.FullName)"
            $skippedSource++
            $errorLog += "Sin permisos: $($file.FullName)"
            return
        }
        
        $batch += $file
        $totalSourceFiles++
        
        if ($batch.Count -ge $batchSize) {
            $batchNumber++
            Write-Host "Procesando lote $batchNumber ($(($batchNumber - 1) * $batchSize + 1) - $($batchNumber * $batchSize))..." -ForegroundColor Yellow
            
            Procesar-Lote -batch $batch -destBySize $destBySize -destByNameSize $destByNameSize `
                -checksumCache $checksumCache -processedDestPaths $processedDestPaths `
                -renombrados ([ref]$renombrados) -noCoinciden ([ref]$noCoinciden) `
                -errorLog ([ref]$errorLog)
            
            $batch = @()
            [System.GC]::Collect()
        }
    }
    catch {
        Write-Warning "Error procesando archivo de origen: $($_.FullName) - $_"
        $skippedSource++
        $errorLog += "Error origen: $($_.FullName) - $_"
    }
}

# Procesar último lote
if ($batch.Count -gt 0) {
    $batchNumber++
    Write-Host "Procesando lote final $batchNumber ($(($batchNumber - 1) * $batchSize + 1) - $totalSourceFiles)..." -ForegroundColor Yellow
    
    Procesar-Lote -batch $batch -destBySize $destBySize -destByNameSize $destByNameSize `
        -checksumCache $checksumCache -processedDestPaths $processedDestPaths `
        -renombrados ([ref]$renombrados) -noCoinciden ([ref]$noCoinciden) `
        -errorLog ([ref]$errorLog)
}

Write-Host "`n════════════════════════════════════" -ForegroundColor Cyan
Write-Host "Resumen:" -ForegroundColor Cyan
Write-Host "Total archivos origen: $totalSourceFiles (Saltados: $skippedSource)" -ForegroundColor Cyan
Write-Host "Total archivos destino: $totalDestFiles (Saltados: $skippedDest)" -ForegroundColor Cyan
Write-Host "✓ Renombrados: $renombrados" -ForegroundColor Green
Write-Host "✗ Problemas: $noCoinciden" -ForegroundColor Red
Write-Host "════════════════════════════════════" -ForegroundColor Cyan

if ($errorLog.Count -gt 0) {
    Write-Host "`nRegistro de errores:" -ForegroundColor Yellow
    $errorLog | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
}
