<#
.SYNOPSIS
    Installs the exact board core + library versions pinned in arduino-deps.txt,
    so a new machine ends up with the same toolchain this repo was built against.

.DESCRIPTION
    Requires arduino-cli on PATH (https://arduino.github.io/arduino-cli/latest/installation/).

    Targets your OS's default Arduino sketchbook folder (Documents\Arduino) via
    the ARDUINO_DIRECTORIES_USER environment variable, regardless of whatever a
    pre-existing arduino-cli.yaml on this machine happens to say -- that's the
    folder Visual Micro / the Arduino IDE actually looks in by default, and
    keeping this script independent of any stale global config avoids installing
    libraries somewhere the IDE won't find them.

    Re-run any time arduino-deps.txt changes (e.g. after a deliberate version
    bump) to bring this machine back in sync.
#>

$ErrorActionPreference = "Stop"

$manifestPath = Join-Path $PSScriptRoot "arduino-deps.txt"
$sketchbookPath = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "Arduino"
$env:ARDUINO_DIRECTORIES_USER = $sketchbookPath

Write-Host "Using Arduino sketchbook: $sketchbookPath"

$boardManagerUrl = "https://github.com/earlephilhower/arduino-pico/releases/download/global/package_rp2040_index.json"
$existingUrls = (arduino-cli config get board_manager.additional_urls) -join "`n"
if ($existingUrls -notmatch [regex]::Escape($boardManagerUrl)) {
    Write-Host "Adding rp2040 board manager URL..."
    arduino-cli config add board_manager.additional_urls $boardManagerUrl
}

Write-Host "Updating board index..."
arduino-cli core update-index

Get-Content $manifestPath | ForEach-Object {
    $line = $_.Trim()
    if ($line -eq "" -or $line.StartsWith("#")) { return }

    if ($line.StartsWith("core:")) {
        $core = $line.Substring(5).Trim()
        Write-Host "Installing core $core ..."
        arduino-cli core install $core
    }
    elseif ($line.StartsWith("lib:")) {
        $lib = $line.Substring(4).Trim()
        Write-Host "Installing library $lib ..."
        arduino-cli lib install "$lib"
    }
}

Write-Host ""
Write-Host "Done. If Visual Micro/Arduino IDE's sketchbook location differs from"
Write-Host "$sketchbookPath, point it there (or move these installs) before building."
