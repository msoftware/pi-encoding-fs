<#
.SYNOPSIS
  Tests pi-encoding-fs (ISO-8859-1 / ISO-8859-15 / Windows-1252 / GB18030) against
  real files from https://github.com/Ousret/char-dataset.

.DESCRIPTION
  1. clones msoftware/pi-encoding-fs and installs its dependencies
  2. clones Ousret/char-dataset (with core.autocrlf=false - IMPORTANT, otherwise git
     rewrites line endings in the legacy-encoded files and corrupts the test data)
  3. copies sample files into a fresh run folder and writes .encoding-converter.json files
  4. runs harness.ts, which loads the extension, executes its read/edit/write/grep tools
     on the copies and verifies the bytes on disk (UTF-8 stays UTF-8, Latin-1 stays
     Latin-1, no U+FFFD, "EUR-Zeichen" is refused in ISO-8859-1, new files get the right bytes ...)

  Requirements: git, Node.js >= 18, npm. Optional: ripgrep (rg) on PATH for the grep checks.
  Works in Windows PowerShell 5.1 and PowerShell 7+ (Windows, Linux, macOS).

.PARAMETER Branch
  Branch of msoftware/pi-encoding-fs to test (default: main).

.PARAMETER WorkDir
  Folder for clones and run folders (default: .\work next to this script).

.EXAMPLE
  .\Test-PiEncoding.ps1
  .\Test-PiEncoding.ps1 -Branch main -WorkDir C:\temp\pi-enc-test
#>
[CmdletBinding()]
param(
  [string]$Branch  = 'main',
  [string]$WorkDir = $(if ($PSScriptRoot) { Join-Path $PSScriptRoot 'work' } else { Join-Path (Get-Location) 'work' })
)

$ErrorActionPreference = 'Stop'
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$Harness   = Join-Path $ScriptDir 'harness.ts'

function Need([string]$cmd) {
  if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { throw "'$cmd' wurde nicht gefunden. Bitte installieren und erneut starten." }
}

# Native commands write progress to stderr; keep that from becoming a terminating error in PS 5.1.
function Invoke-Native {
  param([Parameter(Mandatory)][string]$Exe, [string[]]$Arguments = @())
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & $Exe @Arguments 2>&1 | ForEach-Object { Write-Host "$_" }
    $code = $LASTEXITCODE
  } finally { $ErrorActionPreference = $prev }
  if ($code -ne 0) { throw "'$Exe $($Arguments -join ' ')' endete mit Exit-Code $code" }
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
  [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

Need git; Need node; Need npm
if (-not (Test-Path $Harness)) { throw "harness.ts nicht gefunden (erwartet neben dem Skript): $Harness" }
$nodeMajor = [int]((node --version).TrimStart('v').Split('.')[0])
if ($nodeMajor -lt 18) { throw "Node.js >= 18 erforderlich (gefunden: $(node --version))" }
if (-not (Get-Command rg -ErrorAction SilentlyContinue)) {
  Write-Warning "ripgrep (rg) nicht im PATH - die grep-Pruefungen werden uebersprungen."
}

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$Repo    = Join-Path $WorkDir 'pi-encoding-fs'
$Dataset = Join-Path $WorkDir 'char-dataset'

# -- 1. Extension holen (entspricht dem Stand von `pi install git:github.com/msoftware/pi-encoding-fs`)
Write-Host "`n== Extension: msoftware/pi-encoding-fs ($Branch)" -ForegroundColor Cyan
if (Test-Path (Join-Path $Repo '.git')) {
  Invoke-Native git @('-C', $Repo, 'fetch', '--depth', '1', 'origin', $Branch)
  Invoke-Native git @('-C', $Repo, 'checkout', '-f', '-B', $Branch, 'FETCH_HEAD')
} else {
  Invoke-Native git @('-c', 'core.autocrlf=false', 'clone', '--depth', '1', '--branch', $Branch, 'https://github.com/msoftware/pi-encoding-fs', $Repo)
}
Write-Host ("Commit: " + (git -C $Repo log --oneline -1))
Invoke-Native npm @('install', '--prefix', $Repo, '--no-audit', '--no-fund', '--loglevel', 'error')

# -- 2. Testdaten holen (autocrlf=false ist Pflicht!)
Write-Host "`n== Dataset: Ousret/char-dataset" -ForegroundColor Cyan
if (-not (Test-Path (Join-Path $Dataset '.git'))) {
  $env:GIT_LFS_SKIP_SMUDGE = '1'
  Invoke-Native git @('-c', 'core.autocrlf=false', 'clone', '--depth', '1', 'https://github.com/Ousret/char-dataset', $Dataset)
}

# -- 3. Frischen Lauf-Ordner mit Kopien und Configs anlegen
$Run = Join-Path (Join-Path $WorkDir 'runs') (Get-Date -Format 'yyyyMMdd-HHmmss')
Write-Host "`n== Lauf-Ordner: $Run" -ForegroundColor Cyan
$layout = [ordered]@{
  'iso8859_1'    = @{ Config = '{"sourceEncoding":"ISO-8859-1"}'; Files = @('iso8859_1\_ude_*.txt') }
  'windows_1252' = @{ Config = '{"sourceEncoding":"cp1252"}';     Files = @('windows_1252\*') }
  'gb18030'      = @{ Config = '{"sourceEncoding":"GB18030"}';    Files = @('gb18030\*') }
  # UTF-8-Dateien unter einer Latin-1-Config: der utf8Guard muss sie als UTF-8 behandeln
  'utf_guard'    = @{ Config = '{"sourceEncoding":"latin1"}';     Files = @('utf_8\_ude_1.txt', 'utf_8\bom-utf-8.srt', 'utf_8\finnish-utf-8-latin-1-confusion.html') }
  # Referenz: dieselben UTF-8-Dateien ohne Config (= Pi ohne Extension)
  'plain'        = @{ Config = $null;                              Files = @('utf_8\_ude_1.txt', 'utf_8\bom-utf-8.srt', 'utf_8\finnish-utf-8-latin-1-confusion.html') }
  # nicht unterstuetzte Kodierung -> muss eine klare Fehlermeldung geben
  'cp1250'       = @{ Config = '{"sourceEncoding":"windows-1250"}'; Files = @('windows_1250\_ude_1.txt') }
  # nur fuer neue Dateien
  'iso8859_15'   = @{ Config = '{"sourceEncoding":"ISO-8859-15"}'; Files = @() }
}
foreach ($name in $layout.Keys) {
  $dir = Join-Path $Run $name
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  foreach ($pattern in $layout[$name].Files) {
    # Copy-Item kopiert binaer - die Rohbytes bleiben unveraendert.
    Get-ChildItem -Path (Join-Path $Dataset $pattern) -File | Copy-Item -Destination $dir
  }
  if ($layout[$name].Config) { Write-Utf8NoBom (Join-Path $dir '.encoding-converter.json') $layout[$name].Config }
}

# -- 4. Pruefprogramm ausfuehren (aus dem Repo heraus, damit die Pi-Pakete aufgeloest werden)
Write-Host "`n== Test" -ForegroundColor Cyan
$HarnessCopy = Join-Path $Repo '.harness-run.ts'
Copy-Item $Harness $HarnessCopy -Force
Push-Location $Repo
try {
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  & npx vite-node $HarnessCopy $Run $Repo 2>&1 | ForEach-Object { Write-Host "$_" }
  $exit = $LASTEXITCODE
  $ErrorActionPreference = $prev
} finally {
  Pop-Location
  Remove-Item $HarnessCopy -ErrorAction SilentlyContinue
}

Write-Host ""
if ($exit -eq 0) { Write-Host "ERGEBNIS: alle Pruefungen bestanden (KNOWN = dokumentierte Einschraenkung)." -ForegroundColor Green }
else             { Write-Host "ERGEBNIS: es gab Fehlschlaege (Exit-Code $exit)." -ForegroundColor Red }

Write-Host @"

Manuell mit echtem Pi + Modell ausprobieren (optional):
  pi install git:github.com/msoftware/pi-encoding-fs
  cd "$Run\iso8859_1"
  pi          # dann z.B.: "Lies _ude_2.txt und aendere das Wort 'depend' in 'abhaengig'"
  # danach Kodierung pruefen (PowerShell):
  [System.IO.File]::ReadAllBytes("$Run\iso8859_1\_ude_2.txt")[0..80] | Format-Hex
"@
exit $exit
