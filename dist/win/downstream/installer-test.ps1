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
if ($env:REFRESH_WIZARD -eq 'true') {
  # A packaging-only refresh must wrap the exact already-published app payload.
  $hash = if ($Arch -eq 'arm64') { '76c7db63ce70b0b070e0e7c7e177fea862a93aa57816e52939ba0931d2293b1d' } else { '68c1db1c73cc7927300ac4d60ccdd71c2cc6a46029aa84e92476fbc37fb0e510' }
  $portable = Join-Path $env:RUNNER_TEMP "published-app-$Arch.zip"
  Invoke-WebRequest "https://github.com/travertexs/cryptomator/releases/download/windows-1.20.0-SNAPSHOT/Cryptomator-$Version-windows-$Arch.zip" -OutFile $portable
  if ((Get-FileHash $portable).Hash -ine $hash) { throw 'Published application hash changed.' }
  $staging = Join-Path $env:RUNNER_TEMP "published-image-$Arch"
  Expand-Archive -LiteralPath $portable -DestinationPath $staging
  $image = (Resolve-Path (Join-Path $staging 'Cryptomator')).Path
}
# Use a pinned tool only in the disposable build runner. Do not rely on jpackage's MSI target.
dotnet tool install --tool-path .ci-wix wix --version 6.0.2
if ($LASTEXITCODE) { throw 'WiX installation failed' }
& ./.ci-wix/wix.exe extension add WixToolset.UI.wixext/6.0.2
if ($LASTEXITCODE) { throw 'WiX UI extension installation failed' }
# Generate the same RTF license/third-party notice as upstream's Windows MSI.
$template = (Get-Content -Raw dist/common/licenseTemplate.template.ftl).Replace('###FONT_NAME###','Segoe UI').Replace('###FONT_SIZE###','16').Replace('###WITH_WINFSP###','false').Replace('###COPYRIGHT_END_YEAR###',([datetime]::UtcNow.Year.ToString()))
$template | Set-Content -NoNewline -Encoding ascii dist/win/resources/licenseTemplate.ftl
& ./mvnw.cmd -B license:add-third-party '-Dlicense.thirdPartyFilename=license.rtf' '-Dlicense.outputDirectory=dist/win/resources' '-Dlicense.fileTemplate=dist/win/resources/licenseTemplate.ftl' '-Dlicense.includedScopes=compile' '-Dlicense.excludedGroups=^org\.cryptomator' '-Dlicense.failOnMissing=true'
if ($LASTEXITCODE -or !(Test-Path dist/win/resources/license.rtf)) { throw 'Failed to generate the upstream license page.' }
& ./.ci-wix/wix.exe build -ext WixToolset.UI.wixext -culture en-US dist/win/downstream/installer.wxs -arch $Arch -b "image=$image" -d "Arch=$Arch" -d "UpgradeCode=$uuid" -d "Version=$NumericVersion" -d "AppVersion=$Version" -o $msi
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
      $_.Publisher -eq 'travertexs downstream' -and ($_.DisplayName -like "Cryptomator* ($Arch)" -or $_.DisplayName -like "Cryptomator* (travertexs $Arch)")
    }
  }
  function Assert-UpstreamRegistration {
    $entries = @(Get-ForkRegistration)
    if ($entries.Count -ne 1 -or $entries[0].DisplayName -cne "Cryptomator $Version ($Arch)" -or $entries[0].DisplayVersion -cne $NumericVersion) {
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
# Exercise the actual full-UI MSI, not just msiexec /qn.
& "$PSScriptRoot/test-wizard.ps1" -Msi $msi -Arch $Arch -Version $Version
if ($env:REFRESH_WIZARD -eq 'true') {
  $previous = Join-Path $env:RUNNER_TEMP "previous-$Arch.msi"
  $digest = if ($Arch -eq 'arm64') { 'aef611f39e23511b4e8a84b516d9231a8a150021eaaab675cd8bb7908fe98549' } else { '5924cf30873a07b11e2965353fb97ddd48aca1018cbddfc7f79c23ff2c447a4c' }
  Invoke-WebRequest "https://github.com/travertexs/cryptomator/releases/download/windows-1.20.0-SNAPSHOT/Cryptomator-$Version-windows-$Arch.msi" -OutFile $previous
  if ((Get-FileHash $previous).Hash -ine $digest) { throw 'Previous installer digest mismatch.' }
  Invoke-Msi '/i' 'previous-install.log' $previous
  Invoke-Msi '/i' 'wizard-upgrade.log'
  try {
    Assert-UpstreamRegistration
    $menu = [Environment]::GetFolderPath('CommonPrograms')
    if (!(Test-Path -LiteralPath (Join-Path $menu "Cryptomator ($Arch).lnk")) -or (Test-Path -LiteralPath (Join-Path $menu "Cryptomator (travertexs $Arch).lnk"))) { throw 'Shortcut migration failed.' }
    Write-Host "Same-version upgrade replaced the old name and shortcut ($Arch)."
  } finally { Invoke-Msi '/x' 'wizard-upgrade-uninstall.log' }
}
$zip = Join-Path $out.FullName "Cryptomator-$Version-windows-$Arch.zip"
Compress-Archive -LiteralPath $image -DestinationPath $zip -CompressionLevel Optimal
foreach ($asset in @($msi,$zip)) {
  $name = [IO.Path]::GetFileName($asset)
  ((Get-FileHash -LiteralPath $asset).Hash.ToLowerInvariant() + '  ' + $name) | Set-Content -Encoding ascii (Join-Path $out.FullName "$name.sha256")
}
Write-Host "Install, installed payload verification, startup and uninstall passed for $Arch."
