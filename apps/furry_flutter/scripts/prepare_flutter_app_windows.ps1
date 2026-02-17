param(
  [string]$RepositoryRoot = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSVersion.Major -ge 7) {
  $PSNativeCommandUseErrorActionPreference = $true
}

function Get-DepsSyncHash {
  param([string]$Path)

  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $prefixBytes = [System.Text.Encoding]::UTF8.GetBytes("furry-deps-sync-v1`n")
    [void]$sha.TransformBlock($prefixBytes, 0, $prefixBytes.Length, $null, 0)
    $fileBytes = [System.IO.File]::ReadAllBytes($Path)
    [void]$sha.TransformFinalBlock($fileBytes, 0, $fileBytes.Length)
    return ([System.BitConverter]::ToString($sha.Hash).Replace("-", "").ToLowerInvariant())
  }
  finally {
    $sha.Dispose()
  }
}

$root = (Resolve-Path $RepositoryRoot).Path
$outDir = Join-Path $root "apps\furry_flutter\furry_flutter_app"
$templates = Join-Path $root "apps\furry_flutter\templates"
$depsFile = Join-Path $root "apps\furry_flutter\deps_pins.txt"
$depsStamp = Join-Path $outDir ".dart_tool\furry_deps_stamp"
$pubspecLock = Join-Path $outDir "pubspec.lock"

if (!(Get-Command flutter -ErrorAction SilentlyContinue)) {
  throw "Missing flutter command in PATH"
}
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
else {
  Write-Host "[INFO] Flutter 工程已存在，跳过 flutter create"
}

$depsHash = Get-DepsSyncHash -Path $depsFile
$depsSyncNeeded = $true
if ((Test-Path $depsStamp) -and (Test-Path $pubspecLock)) {
  $prevHashRaw = Get-Content $depsStamp -ErrorAction SilentlyContinue | Select-Object -First 1
  $prevHash = if ($null -eq $prevHashRaw) { "" } else { "$prevHashRaw".Trim() }
  if ($prevHash -eq $depsHash) {
    $depsSyncNeeded = $false
  }
}

Push-Location $outDir
try {
  if ($depsSyncNeeded) {
    Write-Host "[INFO] 添加依赖（pub add）"
    Write-Host "[INFO] 移除已废弃依赖（pub remove）"
    try {
      flutter pub remove just_audio_background just_audio_platform_interface google_fonts mpris *> $null
    }
    catch {
      Write-Host "[INFO] 已废弃依赖不存在，跳过移除"
    }

    $deps = Get-Content $depsFile |
      ForEach-Object { $_.Trim() } |
      Where-Object { $_ -and (-not $_.StartsWith("#")) }
    flutter pub add @deps

    New-Item -ItemType Directory -Force -Path (Split-Path $depsStamp) | Out-Null
    Set-Content -Path $depsStamp -NoNewline -Value $depsHash
  }
  else {
    Write-Host "[INFO] 依赖列表未变化，跳过 flutter pub add/remove"
    flutter pub get
  }
}
finally {
  Pop-Location
}

$localProps = Join-Path $outDir "android\local.properties"
$localPropsBackup = ""
if (Test-Path $localProps) {
  $localPropsBackup = [System.IO.Path]::GetTempFileName()
  Copy-Item -Force $localProps $localPropsBackup
}

Copy-Item -Recurse -Force (Join-Path $templates "lib\*") (Join-Path $outDir "lib")
Copy-Item -Recurse -Force (Join-Path $templates "android\*") (Join-Path $outDir "android")
if ($localPropsBackup) {
  Copy-Item -Force $localPropsBackup $localProps
  Remove-Item -Force $localPropsBackup
}

$generatedRegistrant = Join-Path $outDir "android\app\src\main\java\io\flutter\plugins\GeneratedPluginRegistrant.java"
if (Test-Path $generatedRegistrant) {
  Remove-Item -Force $generatedRegistrant
}

if (Test-Path (Join-Path $templates "test")) {
  Copy-Item -Recurse -Force (Join-Path $templates "test\*") (Join-Path $outDir "test")
}
if (Test-Path (Join-Path $templates "analysis_options.yaml")) {
  Copy-Item -Force (Join-Path $templates "analysis_options.yaml") (Join-Path $outDir "analysis_options.yaml")
}

Write-Host "Prepared Flutter app from templates: $outDir"
