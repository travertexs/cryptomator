# Read only the installer database; never run an official installer just to obtain metadata.
param([Parameter(Mandatory)][string]$Msi)
$wi=New-Object -ComObject WindowsInstaller.Installer
$db=$wi.OpenDatabase($Msi,0)
function Get-Rows([string]$sql,[int]$count) {
  $v=$db.OpenView($sql)
  try {
    $v.Execute()
    while ($r=$v.Fetch()) { $parts=for($i=1;$i -le $count;$i++){$r.StringData($i)}; Write-Output ($parts -join ' | ') }
  } finally { $v.Close() }
}
Get-Rows 'SELECT `Property`,`Value` FROM `Property`' 2 | Where-Object { $_ -match '^(UpgradeCode|ProductCode|ProductVersion|Manufacturer|ProductName) ' }
Get-Rows 'SELECT `Registry`,`Root`,`Key`,`Name`,`Value` FROM `Registry`' 5
Get-Rows 'SELECT `Directory`,`Directory_Parent`,`DefaultDir` FROM `Directory`' 3 | Where-Object { $_ -match '^INSTALLDIR ' }
# Upstream registers the non-advertised associations in Registry, not in
# the optional advertised ProgId / Extension tables.
