# Configuración
$sourceFolder = "C:\Ruta\De\Carpeta1"
$destinationFolder = "C:\Ruta\De\Carpeta2"
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

# Función de checksum optimizada con IncrementalHash (PowerShell 7+) o TransformBlock
function Get-FileChecksum {
    param([string]$filePath)
    
    $fileStream = $null
    $hash = $null
    
    try {
        $fileStream = [System.IO.File]::OpenRead($filePath)
        
        if ($useIncrementalHash) {
            # IncrementalHash: más limpio y nativo de .NET 5+
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
            # TransformBlock: compatible con PowerShell 5.1
            $sha256 = [System.Security.Cryptography.SHA256]::Create()
            $buffer = New-Object byte[] $bufferSize
            $bytesRead = 0
            
            while (($bytesRead = $fileStream.Read($buffer, 0, $bufferSize)) -gt 0) {
                $sha256.TransformBlock($buffer, 0, $bytesRead, $null, 0) | Out-Null
            }
            
            $sha256.TransformFinalBlock($buffer, 0, 0) | Out-Null
            $checksum = $sha256.Hash
            $sha256.Dispose()
        }
        
        return -join ($checksum | ForEach-Object { "{0:x2}" -f $_ })
    }
    catch {
        Write-Error "Error en $filePath : $_"
        return $null
    }
    finally {
        if ($fileStream) {
            $fileStream.Close()
            $fileStream.Dispose()
        }
        if ($hash) {
            $hash.Dispose()
        }
    }
}

Write-Host "PowerShell versión: $($PSVersionTable.PSVersion)" -ForegroundColor Cyan
Write-Host "Usando: $(if ($useIncrementalHash) { 'IncrementalHash' } else { 'TransformBlock' })" -ForegroundColor Yellow
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
$processedDestPaths = @{}

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
        
        Write-Host "Existe: $($src.Name) [$([Math]::Round($src.Length/1MB, 2))MB]" -ForegroundColor DarkGray
        continue
    }
    
    # PASO 2: Si no existe, proceder a comparar por checksum
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
    
    foreach ($dest in $candidates) {
        # Saltar si ya ha sido procesado
        if ($processedDestPaths.ContainsKey($dest.FullName)) {
            continue
        }
        
        # Saltar si es el mismo archivo físico
        if ($dest.FullName -eq $src.FullName) {
            continue
        }
        
        # Saltar si ya existe con el mismo nombre
        if ($dest.Name -eq $src.Name) {
            continue
        }
        
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
                    
                    $processedDestPaths[$dest.FullName] = $true
                    
                    $destByNameSize[$nameSizeKey] = $dest
                    
                    $oldNameSizeKey = "$($dest.Name)|$($dest.Length)"
                    if ($destByNameSize.ContainsKey($oldNameSizeKey)) {
                        $destByNameSize.Remove($oldNameSizeKey)
                    }
                    
                    $dest | Add-Member -MemberType NoteProperty -Name "FullName" -Value $newPath -Force
                    $dest | Add-Member -MemberType NoteProperty -Name "Name" -Value $src.Name -Force
                    
                    $renombrados++
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
