param([Parameter(Mandatory)][ValidateSet('arm64','x64')][string]$Arch,
      [Parameter(Mandatory)][string]$Version)
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
& ./.ci-wix/wix.exe build dist/win/downstream/installer.wxs -arch $Arch -b "image=$image" -d "Arch=$Arch" -d "UpgradeCode=$uuid" -d "Version=$Version" -o $msi
if ($LASTEXITCODE) { throw 'MSI authoring failed' }
$installer = New-Object -ComObject WindowsInstaller.Installer
$info = $installer.SummaryInformation($msi, 0)
$template = $info.Property(7)
if (($template -split ';')[0] -ine $Arch) { throw "Wrong MSI platform: $template" }
Write-Host "Verified MSI platform: $template"
$installed = Join-Path $env:ProgramFiles "Cryptomator-travertexs-$Arch"
if (Test-Path -LiteralPath $installed) { throw 'Refusing to test over an existing installation.' }
function Invoke-Msi([string]$verb,[string]$log) {
  $p = Start-Process msiexec.exe -ArgumentList "$verb ""$msi"" /qn /norestart /l*v ""$env:RUNNER_TEMP/$log""" -PassThru -Wait
  if ($p.ExitCode -notin @(0,3010)) {
    Get-Content (Join-Path $env:RUNNER_TEMP $log) -Tail 100
    throw "msiexec $verb returned $($p.ExitCode)"
  }
}
Invoke-Msi '/i' 'downstream-install.log'
try {
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
$zip = Join-Path $out.FullName "Cryptomator-$Version-windows-$Arch.zip"
Compress-Archive -LiteralPath $image -DestinationPath $zip -CompressionLevel Optimal
foreach ($asset in @($msi,$zip)) {
  $name = [IO.Path]::GetFileName($asset)
  ((Get-FileHash -LiteralPath $asset).Hash.ToLowerInvariant() + '  ' + $name) | Set-Content -Encoding ascii (Join-Path $out.FullName "$name.sha256")
}
Write-Host "Install, installed payload verification, startup and uninstall passed for $Arch."
