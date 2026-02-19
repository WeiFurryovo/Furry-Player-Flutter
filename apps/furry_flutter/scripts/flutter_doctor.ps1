param(
  [string]$RepositoryRoot = (Get-Location).Path,
  [switch]$Strict
)

$ErrorActionPreference = "Stop"

$root = (Resolve-Path $RepositoryRoot).Path
$flutterCmd = ""

$flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
if ($flutterCommand) {
  $flutterCmd = $flutterCommand.Source
}
elseif (Test-Path (Join-Path $root "flutter\bin\flutter.bat")) {
  $flutterCmd = (Join-Path $root "flutter\bin\flutter.bat")
}
elseif (Test-Path (Join-Path $root "flutter\bin\flutter")) {
  $flutterCmd = (Join-Path $root "flutter\bin\flutter")
}
else {
  throw "未找到 flutter 命令，也未找到仓库内 SDK：$root\flutter\bin\flutter(.bat)"
}

$versionText = & $flutterCmd --version
if ($LASTEXITCODE -ne 0) {
  exit $LASTEXITCODE
}
$versionLines = @($versionText)
if ($versionLines.Count -gt 0) {
  Write-Host $versionLines[0]
}

$expectedFlutterVersion = "$env:EXPECTED_FLUTTER_VERSION".Trim()
if ($expectedFlutterVersion) {
  $versionLine = if ($versionLines.Count -gt 0) { "$($versionLines[0])" } else { "" }
  $pattern = "Flutter\s+$([regex]::Escape($expectedFlutterVersion))(\s|$)"
  if ($versionLine -notmatch $pattern) {
    throw "Flutter version mismatch. expected=$expectedFlutterVersion actual='$versionLine'"
  }
}

$expectedDartVersion = "$env:EXPECTED_DART_VERSION".Trim()
if ($expectedDartVersion) {
  $fullText = ($versionLines -join "`n")
  $dartPattern = "Dart\s+$([regex]::Escape($expectedDartVersion))(\s|$)"
  if ($fullText -notmatch $dartPattern) {
    throw "Dart version mismatch. expected=$expectedDartVersion"
  }
}

& $flutterCmd doctor -v
$exitCode = $LASTEXITCODE
if ($Strict -and $exitCode -ne 0) {
  exit $exitCode
}
if (-not $Strict -and $exitCode -ne 0) {
  Write-Warning "flutter doctor exited with code $exitCode; continuing as non-strict."
}
