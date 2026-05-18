#Requires -Version 7
<#
.SYNOPSIS
    Updates OVMS from the latest weekly Windows build on storage.openvinotoolkit.org.

.PARAMETER OvmsDir
    Path to OVMS installation. Defaults to the folder containing this script.

.PARAMETER Restore
    Restore from a previous backup folder (pass the backup folder path).

.EXAMPLE
    .\update-genai.ps1
    .\update-genai.ps1 -Restore "d:\tools\ovms\backup_20260515_143022"
#>
param(
    [string]$OvmsDir = $PSScriptRoot,
    [string]$Restore
)

$ErrorActionPreference = 'Stop'

# ── Restore mode ─────────────────────────────────────────────────────────────
if ($Restore) {
    if (-not (Test-Path $Restore)) { Write-Error "Backup folder not found: $Restore" }
    $items = Get-ChildItem $Restore -Recurse -File
    Write-Host "Restoring $($items.Count) file(s) from $Restore ..."
    foreach ($item in $items) {
        $rel  = $item.FullName.Substring($Restore.Length).TrimStart('\')
        $dest = Join-Path $OvmsDir $rel
        New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
        Copy-Item $item.FullName -Destination $dest -Force
    }
    Write-Host "Restore complete."
    return
}

# ── Discover latest weekly OVMS Windows build ─────────────────────────────────
$filetreeUrl = 'https://storage.openvinotoolkit.org/filetree.json'
Write-Host "Fetching file tree ..."
$raw = (Invoke-WebRequest -Uri $filetreeUrl -UseBasicParsing).Content

# Extract all weekly ovms_windows zip filenames with their version tags
$matches_ = [regex]::Matches($raw, 'openvino_model_server/packages/weekly/([^"]+)/ovms_windows_([^"]+)_python_on\.zip')
if (-not $matches_) {
    # Fall back: search by filename and reconstruct URL from surrounding context
    $matches_ = [regex]::Matches($raw, '"(ovms_windows_([0-9.]+)_python_on\.zip)"')
}

# Parse version+path from filetree context around the weekly section
$weeklyZips = [regex]::Matches($raw, '"name":\s*"(2[0-9.]+\.[a-f0-9]+)"[^}]+?"last modified":\s*"([^"]+)"') |
    ForEach-Object {
        [PSCustomObject]@{
            Version  = $_.Groups[1].Value
            Modified = $_.Groups[2].Value
        }
    } | Sort-Object Modified -Descending

if (-not $weeklyZips) {
    # Direct filename search as fallback
    $allZips = [regex]::Matches($raw, 'ovms_windows_([0-9.]+)_python_on\.zip') |
               ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    $latestTag = $allZips | Select-Object -Last 1
    $versionDir = $latestTag
} else {
    $versionDir = $weeklyZips[0].Version
    $latestTag  = [regex]::Match($versionDir, '(\d+\.\d+)').Groups[1].Value
}

$zipName   = "ovms_windows_${latestTag}_python_on.zip"
$baseUrl   = 'https://storage.openvinotoolkit.org/repositories/openvino_model_server/packages/weekly'
$zipUrl    = "$baseUrl/$versionDir/$zipName"

Write-Host "Weekly build : $versionDir"
Write-Host "Download URL : $zipUrl"

# ── Download ──────────────────────────────────────────────────────────────────
$tmpDir  = Join-Path $env:TEMP 'ovms_weekly_update'
$zipPath = Join-Path $tmpDir $zipName

New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

if ((Test-Path $zipPath) -and (Get-Item $zipPath).Length -gt 10MB) {
    Write-Host "Zip already cached in temp, skipping download."
} else {
    Write-Host "Downloading $zipName ..."
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
    Write-Host "Download complete ($('{0:N0}' -f (Get-Item $zipPath).Length) bytes)."
}

# ── Backup current install ────────────────────────────────────────────────────
$backupDir = Join-Path $OvmsDir "backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
Write-Host "`nBacking up current install to: $backupDir"

# Skip backup_ folders, .claude dir, and this script itself
$skipPatterns = @('backup_*', '.claude', (Split-Path $PSCommandPath -Leaf))
Get-ChildItem $OvmsDir -Recurse -File | Where-Object {
    $rel = $_.FullName.Substring($OvmsDir.Length).TrimStart('\')
    -not ($skipPatterns | Where-Object { $rel -like "$_*" })
} | ForEach-Object {
    $rel  = $_.FullName.Substring($OvmsDir.Length).TrimStart('\')
    $dest = Join-Path $backupDir $rel
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    Copy-Item $_.FullName -Destination $dest
}
Write-Host "Backup complete ($((Get-ChildItem $backupDir -Recurse -File).Count) files)."

# ── Extract and install ───────────────────────────────────────────────────────
Write-Host "`nExtracting ..."
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)

$prefix  = 'ovms/'   # all entries are under this folder in the zip
$total   = ($zip.Entries | Where-Object { -not $_.FullName.EndsWith('/') }).Count
$copied  = 0

foreach ($entry in $zip.Entries) {
    if ($entry.FullName.EndsWith('/')) { continue }   # skip directory entries

    # Strip the leading ovms/ prefix
    $rel  = $entry.FullName.Substring($prefix.Length)
    $dest = Join-Path $OvmsDir $rel

    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
    $copied++
    if ($copied % 200 -eq 0) { Write-Host "  $copied / $total files ..." }
}

$zip.Dispose()

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host @"

Done.
  Installed build : $versionDir
  Files updated   : $copied
  Backup location : $backupDir

To roll back:
  .\update-genai.ps1 -Restore "$backupDir"

To test:
  ovms --model_path "C:\Users\craig\AppData\Local\Programs\AI Playground\resources\models\LLM\openvino\circulus---Qwen3.6-27B-ov-int4" ``
       --model_name QWEN3.6-27B-ov-int4 --port 9000 --rest_port 8000 --log_level DEBUG
"@
