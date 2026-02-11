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

& $flutterCmd doctor -v
$exitCode = $LASTEXITCODE
if ($Strict -and $exitCode -ne 0) {
  exit $exitCode
}
if (-not $Strict -and $exitCode -ne 0) {
  Write-Warning "flutter doctor exited with code $exitCode; continuing as non-strict."
}
