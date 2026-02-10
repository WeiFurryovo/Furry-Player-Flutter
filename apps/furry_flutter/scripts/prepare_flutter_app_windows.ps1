param(
  [string]$RepositoryRoot = (Get-Location).Path
)

$ErrorActionPreference = "Stop"

$root = (Resolve-Path $RepositoryRoot).Path
$outDir = Join-Path $root "apps\furry_flutter\furry_flutter_app"
$templates = Join-Path $root "apps\furry_flutter\templates"
$depsFile = Join-Path $root "apps\furry_flutter\deps_pins.txt"

if (!(Test-Path $depsFile)) {
  throw "Missing deps file: $depsFile"
}
if (!(Test-Path $templates)) {
  throw "Missing templates directory: $templates"
}

if (!(Test-Path $outDir)) {
  New-Item -ItemType Directory -Force -Path (Split-Path $outDir) | Out-Null
  Push-Location (Split-Path $outDir)
  try {
    flutter create --org com.furry --project-name furry_flutter_app --android-language kotlin furry_flutter_app
  }
  finally {
    Pop-Location
  }
}

Push-Location $outDir
try {
  # Pin versions to avoid breaking API changes in dependencies
  # (e.g. file_picker v10 removed FilePicker.platform).
  $deps = Get-Content $depsFile |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and (-not $_.StartsWith("#")) }
  flutter pub add @deps
}
finally {
  Pop-Location
}

Copy-Item -Recurse -Force (Join-Path $templates "lib\*") (Join-Path $outDir "lib")
Copy-Item -Recurse -Force (Join-Path $templates "android\*") (Join-Path $outDir "android")
if (Test-Path (Join-Path $templates "test")) {
  Copy-Item -Recurse -Force (Join-Path $templates "test\*") (Join-Path $outDir "test")
}
if (Test-Path (Join-Path $templates "analysis_options.yaml")) {
  Copy-Item -Force (Join-Path $templates "analysis_options.yaml") (Join-Path $outDir "analysis_options.yaml")
}

Write-Host "Prepared Flutter app from templates: $outDir"
