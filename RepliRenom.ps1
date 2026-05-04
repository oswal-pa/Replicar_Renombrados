# Configuración
$sourceFolder = "C:\Ruta\De\Carpeta1"
$destinationFolder = "C:\Ruta\De\Carpeta2"

# Validar que las carpetas existen
if (-not (Test-Path $sourceFolder)) {
    Write-Error "La carpeta de origen no existe: $sourceFolder"
    exit 1
}

if (-not (Test-Path $destinationFolder)) {
    Write-Error "La carpeta de destino no existe: $destinationFolder"
    exit 1
}

# Función optimizada para calcular SHA256
function Get-FileChecksum {
    param([string]$filePath)
    
    try {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $fileStream = [System.IO.File]::OpenRead($filePath)
        $checksum = $sha256.ComputeHash($fileStream)
        $fileStream.Dispose()
        $sha256.Dispose()
        
        return -join ($checksum | ForEach-Object { "{0:x2}" -f $_ })
    }
    catch {
        Write-Error "Error en $filePath : $_"
        return $null
    }
}

Write-Host "Leyendo archivos..." -ForegroundColor Cyan

# Obtener archivos y agrupar por tamaño (O(n) lookup)
$sourceFiles = @(Get-ChildItem -Path $sourceFolder -File -Recurse)
$destFiles = @(Get-ChildItem -Path $destinationFolder -File -Recurse)

# Crear hash tables para búsqueda rápida O(1)
$destBySize = @{}
$destByChecksum = @{}

# Agrupar destino por tamaño
foreach ($file in $destFiles) {
    if (-not $destBySize.ContainsKey($file.Length)) {
        $destBySize[$file.Length] = @()
    }
    $destBySize[$file.Length] += $file
}

Write-Host "Archivos origen: $($sourceFiles.Count)" -ForegroundColor Green
Write-Host "Archivos destino: $($destFiles.Count)" -ForegroundColor Green

$renombrados = 0
$noCoinciden = 0

# Procesar archivos origen
foreach ($src in $sourceFiles) {
    # Buscar solo archivos con el mismo tamaño (salto rápido)
    $candidates = $destBySize[$src.Length]
    
    if (-not $candidates) {
        continue
    }
    
    $srcChecksum = Get-FileChecksum $src.FullName
    if ($null -eq $srcChecksum) {
        continue
    }
    
    foreach ($dest in $candidates) {
        # Saltar si ya tienen el mismo nombre
        if ($dest.Name -eq $src.Name) {
            break
        }
        
        # Evitar recalcular checksums del mismo archivo
        $cacheKey = "$($dest.FullName)|$($dest.Length)"
        if ($destByChecksum.ContainsKey($cacheKey)) {
            $destChecksum = $destByChecksum[$cacheKey]
        } else {
            $destChecksum = Get-FileChecksum $dest.FullName
            if ($null -eq $destChecksum) {
                continue
            }
            $destByChecksum[$cacheKey] = $destChecksum
        }
        
        # Comparar checksums
        if ($srcChecksum -eq $destChecksum) {
            $newPath = Join-Path -Path $dest.DirectoryName -ChildPath $src.Name
            
            if (Test-Path $newPath) {
                Write-Warning "Existe: $newPath"
                $noCoinciden++
            } else {
                try {
                    Write-Host "Renombrando: $($dest.Name) → $($src.Name)" -ForegroundColor Yellow
                    Rename-Item -Path $dest.FullName -NewName $src.Name -Force -ErrorAction Stop
                    
                    # Actualizar la lista de destino tras el renombramiento
                    $dest.Name = $src.Name
                    $renombrados++
                } catch {
                    Write-Error "Error: $_"
                    $noCoinciden++
                }
            }
            break
        }
    }
}

Write-Host "`nResumen:" -ForegroundColor Cyan
Write-Host "✓ Renombrados: $renombrados" -ForegroundColor Green
Write-Host "✗ Problemas: $noCoinciden" -ForegroundColor Red
