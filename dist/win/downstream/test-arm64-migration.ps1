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
$cases=@('official')
if ($env:ARM64_LAYOUT_REFRESH -eq 'true') {
  $legacy=Download-Msi 'https://github.com/travertexs/cryptomator/releases/download/windows-1.20.0-SNAPSHOT/Cryptomator-1.20.0-SNAPSHOT-windows-arm64.msi' 'old-fork-arm64.msi' '80344a3ab0e14ac7e9c9f860376c44646d6e9de5e54e3dc1e75327363e5c0f21'
  if ((MsiProp $legacy 'UpgradeCode') -ine $legacyCode) { throw 'Unexpected legacy family' }
  $cases+='legacy'
}
$target=Join-Path $env:ProgramFiles 'Cryptomator'
$oldTarget=Join-Path $env:ProgramFiles 'Cryptomator-travertexs-arm64'
$oldKey='HKLM:\Software\travertexs\Cryptomator\arm64'
$newKey="HKLM:\Software\Skymatic GmbH\Cryptomator\$NumericVersion"
$profile=Join-Path $env:APPDATA 'Cryptomator'
New-Item -ItemType Directory -Path $profile -Force | Out-Null
$marker=Join-Path $profile ('installer-test-'+[guid]::NewGuid()+'.txt')
[IO.File]::WriteAllText($marker,'preserve existing user data')
$markerHash=(Get-FileHash $marker).Hash
foreach ($case in $cases) {
  if (@(Codes $officialCode).Count -or @(Codes $legacyCode).Count -or (Test-Path $target) -or (Test-Path $oldTarget)) { throw 'Expected a clean migration test environment.' }
  $pred=if($case -eq 'official') { $up } else { $legacy }
  $family=if($case -eq 'official') { $officialCode } else { $legacyCode }
  Install-Command '/i' $pred "$case-before.log"
  $prevCode=MsiProp $pred 'ProductCode'
  if (@(Codes $family) -notcontains $prevCode) { throw "$case baseline was not installed." }
  if ($case -eq 'official') {
    if (!(Test-Path (Join-Path $target 'Cryptomator.exe'))) { throw 'Official default install location did not match.' }
    $originalVersion=MsiProp $up 'ProductVersion'
    if ((Get-ItemPropertyValue "HKLM:\Software\Skymatic GmbH\Cryptomator\$originalVersion" ProductCode) -ine $prevCode) { throw 'Unexpected official registry layout.' }
  } elseif (!(Test-Path $oldKey) -or !(Test-Path (Join-Path $oldTarget 'Cryptomator.exe'))) { throw 'Old fork layout missing.' }
  Install-Command '/i' $Msi "$case-upgrade.log"
  try {
    $now=@(Codes $officialCode)
    if ($now.Count -ne 1 -or $now[0] -ine $newCode -or @(Codes $legacyCode).Count) { throw 'Duplicate, stale or incorrect product registration.' }
    if ($wi.ProductState($prevCode) -eq 5) { throw 'Previous MSI is still installed.' }
    if ((Get-ItemPropertyValue $newKey ProductCode) -ine $newCode -or (Test-Path $oldKey)) { throw 'Vendor registry migration failed.' }
    if (Test-Path (Join-Path $oldTarget 'Cryptomator.exe')) { throw 'Old launcher still exists.' }
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
  if ((Test-Path (Join-Path $target 'Cryptomator.exe')) -or @(Codes $officialCode).Count -or @(Codes $legacyCode).Count -or (Test-Path $newKey)) { throw 'MSI uninstall left its executable or registration behind.' }
  if ((Get-FileHash $marker).Hash -ne $markerHash) { throw 'Installer changed user data marker.' }
}
