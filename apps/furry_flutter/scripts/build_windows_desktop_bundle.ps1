param(
  [string]$RepositoryRoot = (Get-Location).Path,
  [string]$OutputDir = "dist\desktop\flutter\windows",
  [string]$LogPath = ""
)

$ErrorActionPreference = "Stop"
$env:RUST_BACKTRACE = "1"

$root = (Resolve-Path $RepositoryRoot).Path
$outputDirPath = if ([System.IO.Path]::IsPathRooted($OutputDir)) {
  $OutputDir
}
else {
  Join-Path $root $OutputDir
}

$logFilePath = ""
if ($LogPath) {
  $logFilePath = if ([System.IO.Path]::IsPathRooted($LogPath)) {
    $LogPath
  }
  else {
    Join-Path $root $LogPath
  }
}

$buildAction = {
  param(
    [string]$RepositoryRootPath,
    [string]$OutputDirPath
  )

  cargo --version
  rustc --version
  cargo build --release -p furry_ffi -v

  Push-Location (Join-Path $RepositoryRootPath "apps\furry_flutter\furry_flutter_app")
  try {
    flutter config --enable-windows-desktop
    flutter build windows --release --verbose
  }
  finally {
    Pop-Location
  }

  $dllSrc = Join-Path $RepositoryRootPath "target\release\furry_ffi.dll"
  if (!(Test-Path $dllSrc)) {
    throw "Missing furry_ffi.dll at: $dllSrc"
  }

  $runnerReleaseDir = Join-Path $RepositoryRootPath "apps\furry_flutter\furry_flutter_app\build\windows\x64\runner\Release"
  New-Item -ItemType Directory -Force -Path $runnerReleaseDir | Out-Null
  Copy-Item -Force $dllSrc $runnerReleaseDir

  $dllDst = Join-Path $runnerReleaseDir "furry_ffi.dll"
  if (!(Test-Path $dllDst)) {
    throw "Failed to copy furry_ffi.dll into Release folder"
  }

  New-Item -ItemType Directory -Force -Path $OutputDirPath | Out-Null
  $zipPath = Join-Path $OutputDirPath "furry_flutter_windows.zip"
  Compress-Archive -Path (Join-Path $runnerReleaseDir "*") -DestinationPath $zipPath -Force
  if (!(Test-Path $zipPath)) {
    throw "Failed to create zip bundle: $zipPath"
  }
}

if ($logFilePath) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $logFilePath) | Out-Null
  & {
    & $buildAction $root $outputDirPath
  } 2>&1 | Tee-Object -FilePath $logFilePath
  if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
  }
}
else {
  & $buildAction $root $outputDirPath
  if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
  }
}
