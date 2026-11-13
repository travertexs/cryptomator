param([Parameter(Mandatory)][string]$InstalledDir)
$ErrorActionPreference = 'Stop'
$exe = Resolve-Path (Join-Path $InstalledDir 'Cryptomator (Debug).exe')
$smokeDir = Join-Path $env:RUNNER_TEMP 'cryptomator-hello-selected'
New-Item -ItemType Directory -Path $smokeDir -Force | Out-Null
@{ useKeychain = $true; keychainProvider = 'org.cryptomator.windows.keychain.WindowsHelloKeychainAccess'; directories = @() } |
  ConvertTo-Json | Set-Content -LiteralPath (Join-Path $smokeDir 'settings.json') -Encoding utf8
$cfg = Join-Path $InstalledDir 'app\Cryptomator (Debug).cfg'
$originalCfg = Get-Content -LiteralPath $cfg -Raw
$smokePath = $smokeDir.Replace('\', '/')
$testOptions = @(
  "java-options=-Dcryptomator.settingsPath=$smokePath/settings.json",
  "java-options=-Dcryptomator.logDir=$smokePath",
  "java-options=-Dcryptomator.ipcSocketPath=$smokePath/ipc.socket",
  "java-options=-Dcryptomator.integrationsWin.windowsHelloKeychainPaths=$smokePath/windowsHelloKeychain.json",
  "java-options=-Dcryptomator.integrationsWin.keychainPaths=$smokePath/keychain.json",
  "java-options=-XX:ErrorFile=$smokePath/hs_err_pid%p.log"
)
$testCfg = $originalCfg
foreach ($option in $testOptions) {
  $prefix = $option.Substring(0, $option.LastIndexOf('='))
  $pattern = '(?m)^' + [regex]::Escape($prefix) + '=.*$'
  if (-not [regex]::IsMatch($testCfg, $pattern)) { throw "Missing smoke-test option: $prefix" }
  $testCfg = [regex]::Replace($testCfg, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $option })
}
Set-Content -LiteralPath $cfg -Value $testCfg -Encoding utf8 -NoNewline
$process = Start-Process -FilePath $exe -WorkingDirectory $InstalledDir `
  -WindowStyle Hidden -RedirectStandardOutput smoke.stdout.txt -RedirectStandardError smoke.stderr.txt -PassThru
try {
  Start-Sleep -Seconds 20
  $process.Refresh()
  if ($process.HasExited) {
    Write-Host '--- stdout ---'
    if (Test-Path smoke.stdout.txt) { Get-Content smoke.stdout.txt }
    Write-Host '--- stderr ---'
    if (Test-Path smoke.stderr.txt) { Get-Content smoke.stderr.txt }
    Get-ChildItem -LiteralPath $smokeDir -Filter 'hs_err_pid*.log' -ErrorAction SilentlyContinue |
      ForEach-Object {
        Write-Host "--- $($_.Name) ---"
        Get-Content -LiteralPath $_.FullName
      }
    throw "Cryptomator exited during the installed application smoke test with code $($process.ExitCode)."
  }
  Write-Host "Cryptomator remained running for 20 seconds after installation on the native $env:TARGET_ARCH runner."
} finally {
  Set-Content -LiteralPath $cfg -Value $originalCfg -Encoding utf8 -NoNewline
  if (-not $process.HasExited) {
    & taskkill.exe /PID $process.Id /T /F
  }
}

$launcherConfigs = Get-ChildItem -LiteralPath (Join-Path $InstalledDir 'app') -Filter '*.cfg'
if ($launcherConfigs | Select-String -SimpleMatch 'cryptomator.keychain.disabledProviders') {
  throw 'The packaged launcher still disables a keychain provider.'
}
