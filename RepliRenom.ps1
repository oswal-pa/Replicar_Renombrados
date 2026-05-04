# Configuración
$sourceFolder = "C:\Ruta\De\Carpeta1"  # Carpeta original
$destinationFolder = "C:\Ruta\De\Carpeta2"  # Carpeta de destino

# Validar que las carpetas existen
if (-not (Test-Path $sourceFolder)) {
    Write-Error "La carpeta de origen no existe: $sourceFolder"
    exit 1
}

if (-not (Test-Path $destinationFolder)) {
    Write-Error "La carpeta de destino no existe: $destinationFolder"
    exit 1
}

# Función para calcular el checksum SHA256 de un archivo
function Get-FileChecksum {
    param([string]$filePath)
    
    try {
        $fileStream = [System.IO.File]::Open($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read)
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $checksum = $sha256.ComputeHash($fileStream)
        $fileStream.Close()
        $sha256.Dispose()
        
        return -join ($checksum | ForEach-Object { "{0:x2}" -f $_ })
    }
    catch {
        Write-Error "Error al calcular checksum de $filePath : $_"
        return $null
    }
}

# Obtener los archivos de ambas carpetas
Write-Host "Leyendo archivos de carpetas..." -ForegroundColor Cyan
$sourceFiles = Get-ChildItem -Path $sourceFolder -File -Recurse
$destinationFiles = Get-ChildItem -Path $destinationFolder -File -Recurse

if ($sourceFiles.Count -eq 0 -or $destinationFiles.Count -eq 0) {
    Write-Warning "Una o ambas carpetas no contienen archivos."
    exit 0
}

Write-Host "Archivos origen: $($sourceFiles.Count)" -ForegroundColor Green
Write-Host "Archivos destino: $($destinationFiles.Count)" -ForegroundColor Green

$renombrados = 0
$noCoinciden = 0

foreach ($src in $sourceFiles) {
    # Comprobar archivos en el destino con el mismo tamaño
    $potentialMatches = @($destinationFiles | Where-Object { $_.Length -eq $src.Length })
    
    if ($potentialMatches.Count -eq 0) {
        continue
    }
    
    $srcChecksum = Get-FileChecksum $src.FullName
    if ($null -eq $srcChecksum) {
        continue
    }
    
    foreach ($dest in $potentialMatches) {
        # No renombrar si ya tienen el mismo nombre
        if ($dest.Name -eq $src.Name) {
            break
        }
        
        $destChecksum = Get-FileChecksum $dest.FullName
        if ($null -eq $destChecksum) {
            continue
        }
        
        # Comparar checksums
        if ($srcChecksum -eq $destChecksum) {
            $newPath = Join-Path -Path $dest.DirectoryName -ChildPath $src.Name
            
            # Verificar si ya existe un archivo con el nuevo nombre
            if (Test-Path $newPath) {
                Write-Warning "No se puede renombrar: Ya existe $newPath"
                $noCoinciden++
            } else {
                try {
                    Write-Host "Renombrando: $($dest.Name) → $($src.Name)" -ForegroundColor Yellow
                    Rename-Item -Path $dest.FullName -NewName $src.Name -Force
                    $renombrados++
                }
                catch {
                    Write-Error "Error al renombrar $($dest.FullName): $_"
                    $noCoinciden++
                }
            }
            break
        }
    }
}

# Resumen
Write-Host "`nResumen:" -ForegroundColor Cyan
Write-Host "Archivos renombrados correctamente: $renombrados" -ForegroundColor Green
Write-Host "Archivos con problemas: $noCoinciden" -ForegroundColor Red
