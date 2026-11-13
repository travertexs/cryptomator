param([Parameter(Mandatory)][string]$Msi,[Parameter(Mandatory)][string]$Image,
      [Parameter(Mandatory)][string]$Version,[Parameter(Mandatory)][string]$NumericVersion)
$ErrorActionPreference='Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne 'Arm64') { throw 'Requires a disposable native ARM64 Windows runner.' }
$officialCode='{BDA45523-42B1-4CAE-9354-A45475ED4775}'
$legacyCode='{A7D02CE3-73DA-4D70-9DBF-8E7F7E0F7459}'
$wi=New-Object -ComObject WindowsInstaller.Installer
function Codes($family) {
  $list=$wi.RelatedProducts($family)
  for($i=0;$i -lt $list.Count;$i++){ [string]$list.Item($i) }
}
function MsiProp($file,$name) {
  $db=$wi.OpenDatabase($file,0)
  $query = 'SELECT `Value` FROM `Property` WHERE `Property`=''{0}''' -f $name
  $v=$db.OpenView($query)
  try {
    $null=$v.Execute()
    $row=$v.Fetch()
    if ($null -eq $row) { throw "No such MSI property: $name" }
    $value=[string]$row.StringData(1)
  } finally { $null=$v.Close() }
  return $value
}
function Download-Msi($url,$name,$hash) {
  $p=Join-Path $env:RUNNER_TEMP $name
  Invoke-WebRequest $url -OutFile $p
  if ((Get-FileHash -LiteralPath $p).Hash -ine $hash) { throw "Wrong digest of $name" }; $p
}
function Install-Command($verb,$file,$log) {
  $logPath=Join-Path $env:RUNNER_TEMP $log
  $p=Start-Process msiexec.exe -PassThru -Wait -ArgumentList "$verb ""$file"" /qn /norestart /l*v ""$logPath"""
  if ($p.ExitCode -notin @(0,3010)) { Get-Content -LiteralPath $logPath -Tail 100; throw "MSI $verb failed ($($p.ExitCode)), $log" }
}
$up=Download-Msi 'https://github.com/cryptomator/cryptomator/releases/download/1.19.6/Cryptomator-1.19.6-x64.msi' 'official-1.19.6.msi' 'ad416a6dff6ad969c2c346a9050b650e49fe5da9ac30c948148ae6b8412ebbce'
$uFamily=MsiProp $up 'UpgradeCode'
$aFamily=MsiProp $Msi 'UpgradeCode'
Write-Host "MSI identity: official='$uFamily'; ARM64='$aFamily'; expected='$officialCode'."
if ($uFamily -ine $officialCode -or $aFamily -ine $officialCode) { throw 'Product family differs from upstream' }
$newCode=MsiProp $Msi 'ProductCode'
if ((MsiProp $up 'ProductCode') -ieq $newCode) { throw 'An upstream ProductCode must not be reused.' }
$cases=@('official-1.19.6')
if ($env:ARM64_LAYOUT_REFRESH -eq 'true') {
  $up195=Download-Msi 'https://github.com/cryptomator/cryptomator/releases/download/1.19.5/Cryptomator-1.19.5-x64.msi' 'official-1.19.5.msi' '36606757e2bcdead1300e25151c6519b82134f2cf12afb1dd5033ca9b2a8b774'
  $legacy=(Resolve-Path '.arm64/previous-fork/Cryptomator-1.20.0-SNAPSHOT-windows-arm64.msi').Path
  if ((MsiProp $up195 'ProductCode') -ine '{A254D476-5EB1-33A7-AA38-61F3833656DE}' -or (MsiProp $legacy 'UpgradeCode') -ine $legacyCode -or (MsiProp $legacy 'ProductName') -cne 'Cryptomator 1.20.0-SNAPSHOT (travertexs arm64)') { throw 'Unexpected coexistence fixture identity.' }
  $cases+='official-1.19.5-with-separate-fork'
}
$target=Join-Path $env:ProgramFiles 'Cryptomator'
$oldTarget=Join-Path $env:ProgramFiles 'Cryptomator-travertexs-arm64'
$menu=[Environment]::GetFolderPath('CommonPrograms')
$oldLink=Join-Path $menu 'Cryptomator (travertexs arm64).lnk'
$oldExe=Join-Path $oldTarget 'Cryptomator.exe'
$arp='HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
$newKey="HKLM:\Software\Skymatic GmbH\Cryptomator\$NumericVersion"
$profile=Join-Path $env:APPDATA 'Cryptomator'
New-Item -ItemType Directory -Path $profile -Force | Out-Null
$marker=Join-Path $profile ('installer-test-'+[guid]::NewGuid()+'.txt')
[IO.File]::WriteAllText($marker,'preserve existing user data')
$markerHash=(Get-FileHash $marker).Hash
function Assert-SeparateFork {
  $side=@(Codes $legacyCode)
  if ($side.Count -ne 1 -or $side[0] -ine $sideCode -or (Get-ItemPropertyValue "$arp\$sideCode" DisplayName) -cne $sideName -or (Get-FileHash $oldExe).Hash -ne $sideHashes[0] -or (Get-FileHash $oldLink).Hash -ne $sideHashes[1]) { throw 'Separate legacy fork registration, executable or shortcut changed.' }
}
# Compare actual Windows-rendered icons, not hashes of the differently compiled PE containers.
Add-Type -AssemblyName System.Drawing.Common
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ProductIconNative {
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern uint PrivateExtractIcons(string file, int index, int width, int height, IntPtr[] icons, uint[] ids, uint count, uint flags);
  [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr icon);
}
'@
function Get-InstallerIconDigest($cachedPath) {
  foreach ($px in @(16,32,48,256)) {
    $handles=[IntPtr[]]::new(1)
    if ([ProductIconNative]::PrivateExtractIcons($cachedPath,0,$px,$px,$handles,[uint32[]]::new(1),1,0) -ne 1 -or $handles[0] -eq [IntPtr]::Zero) { throw "Could not render $px px product icon from $cachedPath" }
    try {
      $icon=[System.Drawing.Icon]::FromHandle($handles[0])
      $bitmap=$icon.ToBitmap()
      $stream=[IO.MemoryStream]::new()
      try {
        $bitmap.Save($stream,[System.Drawing.Imaging.ImageFormat]::Png)
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream.ToArray()))
      } finally { $stream.Dispose(); $bitmap.Dispose(); $icon.Dispose() }
    } finally { $null=[ProductIconNative]::DestroyIcon($handles[0]) }
  }
}
foreach ($case in $cases) {
  if (@(Codes $officialCode).Count -or @(Codes $legacyCode).Count -or (Test-Path $target) -or (Test-Path $oldTarget)) { throw 'Expected a clean migration test environment.' }
  $coexist=$case -eq 'official-1.19.5-with-separate-fork'
  $pred=if($coexist) { $up195 } else { $up }
  Install-Command '/i' $pred "$case-before.log"
  $prevCode=MsiProp $pred 'ProductCode'
  if (@(Codes $officialCode) -notcontains $prevCode) { throw "$case baseline was not installed." }
  $officialName=Get-ItemPropertyValue "$arp\$prevCode" DisplayName
  $officialIcon=$wi.ProductInfo($prevCode,'ProductIcon')
  $expectedIcon=(Get-InstallerIconDigest $officialIcon) -join ';'
  if ($officialName -cne 'Cryptomator') { throw "Unexpected official name: $officialName" }
  if ($coexist) {
    Install-Command '/i' $legacy "$case-side-by-side.log"
    $sideCode=MsiProp $legacy 'ProductCode'
    $sideName=Get-ItemPropertyValue "$arp\$sideCode" DisplayName
    $sideHashes=@((Get-FileHash $oldExe).Hash,(Get-FileHash $oldLink).Hash)
  }
  if (!(Test-Path (Join-Path $target 'Cryptomator.exe'))) { throw 'Official default install location did not match.' }
  $originalVersion=MsiProp $pred 'ProductVersion'
  if ((Get-ItemPropertyValue "HKLM:\Software\Skymatic GmbH\Cryptomator\$originalVersion" ProductCode) -ine $prevCode) { throw 'Unexpected official registry layout.' }
  Install-Command '/i' $Msi "$case-upgrade.log"
  try {
    $now=@(Codes $officialCode)
    if ($now.Count -ne 1 -or $now[0] -ine $newCode) { throw 'Duplicate, stale or incorrect official-family registration.' }
    if ($wi.ProductState($prevCode) -eq 5) { throw 'Previous MSI is still installed.' }
    if ((Get-ItemPropertyValue $newKey ProductCode) -ine $newCode -or (Test-Path "$arp\$prevCode")) { throw 'Vendor registry migration failed.' }
    if ((Get-ItemPropertyValue "$arp\$newCode" DisplayName) -cne $officialName) { throw 'Installed apps display name differs from upstream.' }
    $actualIcon=(Get-InstallerIconDigest ($wi.ProductInfo($newCode,'ProductIcon'))) -join ';'
    if ($actualIcon -ne $expectedIcon) { throw "Installed apps icon differs from official: $actualIcon vs $expectedIcon" }
    if (!(Test-Path (Join-Path $menu 'Cryptomator.lnk'))) { throw 'Upstream-named shortcut missing after replacement.' }
    if ($coexist) { Assert-SeparateFork } elseif (@(Codes $legacyCode).Count) { throw 'Unexpected fork entry.' }
    $loc=$wi.ProductInfo($newCode,'InstallLocation')
    if (!$loc -or $loc.TrimEnd('\') -ine $target) { throw "Unexpected registered install location: $loc" }
    foreach ($f in Get-ChildItem -LiteralPath $Image -Recurse -File -Force) {
      $rel=[IO.Path]::GetRelativePath($Image,$f.FullName)
      if ((Get-FileHash $f.FullName).Hash -ne (Get-FileHash (Join-Path $target $rel)).Hash) { throw "Wrong installed payload after $case migration: $rel" }
    }
    $exe=Join-Path $target 'Cryptomator.exe'
    $bytes=[IO.File]::ReadAllBytes($exe)
    if ([BitConverter]::ToUInt16($bytes,([BitConverter]::ToInt32($bytes,60)+4)) -ne 0xAA64) { throw 'Installed launcher is not ARM64.' }
    $cls='Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes'
    $progid=(Get-Item -LiteralPath "$cls\.cryptomator").GetValue('')
    $open=(Get-Item -LiteralPath "$cls\$progid\shell\open\command").GetValue('')
    if ($progid -ne 'progidc09ad15393a23d2fa9ebb7a73954c60b' -or !$open.Contains($exe) -or !$open.Contains('"%1"')) { throw "Incorrect vault-file open command: $open" }
    foreach ($ext in @('c9r','c9s','c9u')) {
      if ((Get-Item -LiteralPath "$cls\.$ext").GetValue('') -ne 'Cryptomator.Encrypted.1') { throw "Incorrect .$ext association" }
    }
    & "$PSScriptRoot/smoke-installed.ps1" -InstalledDir $target
    Write-Host "Verified $case in-place ARM64 replacement: one upstream MSI family entry, correct vendor path and associations, exact native payload, working startup in $target."
  } finally { Install-Command '/x' $Msi "$case-remove.log" }
  if ((Test-Path (Join-Path $target 'Cryptomator.exe')) -or @(Codes $officialCode).Count -or (Test-Path $newKey)) { throw 'MSI uninstall left its executable or registration behind.' }
  if ($coexist) {
    Assert-SeparateFork
    Write-Host "Official 1.19.5.6584 replaced; separate old fork entry, launcher and shortcut remained intact across upgrade and uninstall. Official display name and icon verified."
    Install-Command '/x' $legacy "$case-remove-fixture.log"
  }
  if ((Get-FileHash $marker).Hash -ne $markerHash) { throw 'Installer changed user data marker.' }
}
