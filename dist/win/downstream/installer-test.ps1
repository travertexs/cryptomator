param([Parameter(Mandatory)][ValidateSet('arm64','x64')][string]$Arch,
      [Parameter(Mandatory)][string]$Version,
      [Parameter(Mandatory)][string]$NumericVersion)
$ErrorActionPreference = 'Stop'
$expectedNative = if ($Arch -eq 'arm64') { 'Arm64' } else { 'X64' }
if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne $expectedNative) { throw 'Wrong native Windows runner' }
$image = (Resolve-Path appdir/Cryptomator).Path
$uuid = if ($Arch -eq 'arm64') { 'A7D02CE3-73DA-4D70-9DBF-8E7F7E0F7459' } else { '9FDD5F11-9382-487D-93FA-0AD53762C44B' }
$out = New-Item -ItemType Directory -Force release
$msi = Join-Path $out.FullName "Cryptomator-$Version-windows-$Arch.msi"
# Use a pinned tool only in the disposable build runner. Do not rely on jpackage's MSI target.
dotnet tool install --tool-path .ci-wix wix --version 6.0.2
if ($LASTEXITCODE) { throw 'WiX installation failed' }
& ./.ci-wix/wix.exe build dist/win/downstream/installer.wxs -arch $Arch -b "image=$image" -d "Arch=$Arch" -d "UpgradeCode=$uuid" -d "Version=$NumericVersion" -d "AppVersion=$Version" -o $msi
if ($LASTEXITCODE) { throw 'MSI authoring failed' }
$installer = New-Object -ComObject WindowsInstaller.Installer
$info = $installer.SummaryInformation($msi, 0)
$template = $info.Property(7)
if (($template -split ';')[0] -ine $Arch) { throw "Wrong MSI platform: $template" }
Write-Host "Verified MSI platform: $template"
$installed = Join-Path $env:ProgramFiles "Cryptomator-travertexs-$Arch"
if (Test-Path -LiteralPath $installed) { throw 'Refusing to test over an existing installation.' }
function Invoke-Msi([string]$verb,[string]$log,[string]$package=$msi) {
  $p = Start-Process msiexec.exe -ArgumentList "$verb ""$package"" /qn /norestart /l*v ""$env:RUNNER_TEMP/$log""" -PassThru -Wait
  if ($p.ExitCode -notin @(0,3010)) {
    Get-Content (Join-Path $env:RUNNER_TEMP $log) -Tail 100
    throw "msiexec $verb returned $($p.ExitCode)"
  }
}
Invoke-Msi '/i' 'downstream-install.log'
try {
  $cfg = Get-Content -LiteralPath (Join-Path $installed 'app/Cryptomator.cfg')
  if ($cfg -cnotcontains "java-options=-Dcryptomator.appVersion=$Version") { throw 'Installed app version differs from upstream.' }
  if (-not (Test-Path -LiteralPath (Join-Path $installed "app/mods/cryptomator-$Version.jar"))) { throw 'Installed app JAR version differs from upstream.' }
  function Get-ForkRegistration {
    Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' | Where-Object {
      $_.Publisher -eq 'travertexs downstream' -and $_.DisplayName -like "Cryptomator* (travertexs $Arch)"
    }
  }
  function Assert-UpstreamRegistration {
    $entries = @(Get-ForkRegistration)
    if ($entries.Count -ne 1 -or $entries[0].DisplayName -cne "Cryptomator $Version (travertexs $Arch)" -or $entries[0].DisplayVersion -cne $NumericVersion) {
      throw 'Expected exactly one registered installer with the correct upstream display name and numeric MSI version.'
    }
  }
  Assert-UpstreamRegistration
  # Compare every installed payload byte to the architecture-checked app image.
  foreach ($file in Get-ChildItem -LiteralPath $image -Recurse -File -Force) {
    $rel = [IO.Path]::GetRelativePath($image,$file.FullName)
    $target = Join-Path $installed $rel
    if ((Get-FileHash -LiteralPath $file.FullName).Hash -ne (Get-FileHash -LiteralPath $target).Hash) { throw "Installed payload mismatch: $rel" }
  }
  & "$PSScriptRoot/smoke-installed.ps1" -InstalledDir $installed
} finally {
  Invoke-Msi '/x' 'downstream-uninstall.log'
}
if (Test-Path -LiteralPath (Join-Path $installed 'Cryptomator.exe')) { throw 'Uninstall left the launcher behind.' }
if ($env:TEST_SUPERSEDED -eq 'true') {
  $previous = Join-Path $env:RUNNER_TEMP "previous-$Arch.msi"
  $digest = if ($Arch -eq 'arm64') { '1f672cffcf3734a6f1c5348b3d2f9f5804b80feb6e8f8c0e7f64d181c1bd4935' } else { '71d786f854c71fe664f81c4fc128e630b9183dea0c02c0752ba1a276b5929271' }
  Invoke-WebRequest "https://github.com/travertexs/cryptomator/releases/download/windows-1.20.0/Cryptomator-1.20.0-windows-$Arch.msi" -OutFile $previous
  if ((Get-FileHash $previous).Hash -ine $digest) { throw 'Superseded MSI digest mismatch.' }
  Invoke-Msi '/i' 'downstream-previous-install.log' $previous
  Invoke-Msi '/i' 'downstream-replacement-install.log'
  try {
    Assert-UpstreamRegistration
    if ((Get-Content -LiteralPath (Join-Path $installed 'app/Cryptomator.cfg')) -cnotcontains "java-options=-Dcryptomator.appVersion=$Version") { throw 'Version was not corrected by upgrade.' }
    Write-Host "In-place correction from 1.20.0 to $Version passed ($Arch)."
  } finally { Invoke-Msi '/x' 'downstream-replacement-uninstall.log' }
}
$zip = Join-Path $out.FullName "Cryptomator-$Version-windows-$Arch.zip"
Compress-Archive -LiteralPath $image -DestinationPath $zip -CompressionLevel Optimal
foreach ($asset in @($msi,$zip)) {
  $name = [IO.Path]::GetFileName($asset)
  ((Get-FileHash -LiteralPath $asset).Hash.ToLowerInvariant() + '  ' + $name) | Set-Content -Encoding ascii (Join-Path $out.FullName "$name.sha256")
}
Write-Host "Install, installed payload verification, startup and uninstall passed for $Arch."
