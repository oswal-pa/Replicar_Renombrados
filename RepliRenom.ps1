
# Configuración
$sourceFolder = "C:\Ruta\De\Carpeta1"  # Carpeta original
$destinationFolder = "C:\Ruta\De\Carpeta2"  # Carpeta de destino

# Función para calcular el checksum SHA256 de un archivo
function Get-FileChecksum($filePath) {
    $fileStream = [System.IO.File]::Open($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read)
    try {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $checksum = $sha256.ComputeHash($fileStream)
        return -join ($checksum | ForEach-Object { "{0:x2}" -f $_ })
    } finally {
        $fileStream.Close()
    }
}

# Obtener los archivos de ambas carpetas
$sourceFiles = Get-ChildItem -Path $sourceFolder -File -Recurse
$destinationFiles = Get-ChildItem -Path $destinationFolder -File -Recurse

foreach ($src in $sourceFiles) {
    # Comprobar archivos en el destino con el mismo tamaño
    $potentialMatches = $destinationFiles | Where-Object { $_.Length -eq $src.Length }
    foreach ($dest in $potentialMatches) {
        # Comparar el checksum SHA256
        if ((Get-FileChecksum $src.FullName) -eq (Get-FileChecksum $dest.FullName)) {
            # Renombrar archivo en la carpeta de destino para que coincida con el de origen
            $newPath = Join-Path -Path $dest.DirectoryName -ChildPath $src.Name
            if ($dest.FullName -ne $newPath) {
                Write-Host "Renombrando $($dest.FullName) a $newPath"
                Rename-Item -Path $dest.FullName -NewName $src.Name
            }
            break
        }
    }
}
