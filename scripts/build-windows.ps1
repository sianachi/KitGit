$ErrorActionPreference = 'Stop'
Push-Location (Join-Path $PSScriptRoot '..')
try {
    python -c 'import tkinter'
    if ($LASTEXITCODE -ne 0) { throw 'Install Python for Windows with Tcl/Tk support.' }
    Get-Command git.exe -ErrorAction Stop | Out-Null
    swift build -c release
    if ($LASTEXITCODE -ne 0) { throw 'KitGit build failed.' }
    $bin = swift build -c release --show-bin-path
    if ($LASTEXITCODE -ne 0) { throw 'Could not find the KitGit build output.' }
    $app = New-Item -Force -ItemType Directory .build/KitGit-windows
    Copy-Item (Join-Path $bin 'KitGit.exe') (Join-Path $app.FullName 'engine.exe') -Force
    Copy-Item Desktop/kitgit.py, Resources/KitGit.png, Desktop/KitGit.cmd $app.FullName -Force
    Write-Output (Join-Path $app.FullName 'KitGit.cmd')
} finally {
    Pop-Location
}
