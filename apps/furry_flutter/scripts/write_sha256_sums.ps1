param(
  [Parameter(Mandatory = $true)]
  [string]$OutputFile,
  [Parameter(Mandatory = $true)]
  [string[]]$Files
)

$ErrorActionPreference = "Stop"

if ($Files.Count -eq 0) {
  throw "At least one input file is required."
}

$outDir = Split-Path -Parent $OutputFile
if ($outDir) {
  New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}

$lines = foreach ($file in $Files) {
  if (!(Test-Path $file)) {
    throw "Missing file for checksum: $file"
  }

  $hash = (Get-FileHash $file -Algorithm SHA256).Hash.ToLower()
  $name = Split-Path -Leaf $file
  "$hash  $name"
}

$lines | Out-File -Encoding ascii $OutputFile
