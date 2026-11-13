param([Parameter(Mandatory)][string]$Msi,[Parameter(Mandatory)][string]$Arch,[Parameter(Mandatory)][string]$Version)
$ErrorActionPreference='Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_OS -ne 'Windows') { throw 'This interactive test is for disposable Windows Actions runners only.' }
# Inspect only our MSI window (not a screenshot/scan of the whole desktop).
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Runtime.InteropServices;
using System.Diagnostics;
public static class WizardWindow {
  public delegate bool EnumProc(IntPtr w,IntPtr p);
  [DllImport("user32")] static extern bool EnumWindows(EnumProc f,IntPtr p);
  [DllImport("user32")] static extern bool EnumChildWindows(IntPtr w,EnumProc f,IntPtr p);
  [DllImport("user32")] public static extern bool IsWindowVisible(IntPtr w);
  [DllImport("user32")] public static extern bool IsWindowEnabled(IntPtr w);
  [DllImport("user32",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr w,StringBuilder t,int n);
  [DllImport("user32",CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr w,StringBuilder t,int n);
  [DllImport("user32",CharSet=CharSet.Unicode)] static extern IntPtr SendMessageTimeout(IntPtr w,uint m,IntPtr p,StringBuilder s,uint f,uint ms,out IntPtr r);
  [DllImport("user32")] static extern uint GetWindowThreadProcessId(IntPtr w,out int pid);
  [DllImport("user32")] static extern bool PostMessage(IntPtr w,uint m,IntPtr a,IntPtr b);
  public static string Label(IntPtr w){var b=new StringBuilder(1024);IntPtr r;SendMessageTimeout(w,13,(IntPtr)b.Capacity,b,2,500,out r);return b.ToString().Replace("&","").Trim();}
  public static string Kind(IntPtr w){var b=new StringBuilder(128);GetClassName(w,b,128);return b.ToString();}
  public static IntPtr Window(string title){IntPtr found=IntPtr.Zero;EnumWindows((w,p)=>{var b=new StringBuilder(256);GetWindowText(w,b,256); if(b.ToString()!=title||!IsWindowVisible(w))return true;int pid;GetWindowThreadProcessId(w,out pid);try { if(!Process.GetProcessById(pid).ProcessName.Equals("msiexec",StringComparison.OrdinalIgnoreCase))return true; }catch{return true;}found=w;return false;},IntPtr.Zero);return found;}
  public static IntPtr[] Controls(IntPtr w){var list=new List<IntPtr>();EnumChildWindows(w,(c,p)=>{if(IsWindowVisible(c))list.Add(c);return true;},IntPtr.Zero);return list.ToArray();}
  public static void Click(IntPtr w){if(!IsWindowEnabled(w)||!PostMessage(w,0x00F5,IntPtr.Zero,IntPtr.Zero))throw new Exception("Could not click enabled MSI control");}
}
'@
$title = if ($Arch -eq 'arm64') { 'Cryptomator Setup' } else { "Cryptomator $Version ($Arch) Setup" }
$dir = New-Item -ItemType Directory -Path (Join-Path $env:RUNNER_TEMP "wizard-$Arch") -Force
function Open-Wizard([string]$name) {
  $script:process = Start-Process msiexec.exe -ArgumentList "/i ""$Msi"" /qf /norestart /l*v ""$($dir.FullName)/$name.log""" -PassThru
}
function Wait-Button([string]$pattern,[string]$step,[switch]$AllowDisabled) {
  $deadline = [datetime]::UtcNow.AddSeconds(90)
  do {
    $window = [WizardWindow]::Window($title)
    $seen = @()
    if ($window -ne [IntPtr]::Zero) {
      foreach ($h in [WizardWindow]::Controls($window)) {
        if ([WizardWindow]::Kind($h) -ne 'Button') { continue }
        $name = [WizardWindow]::Label($h)
        $seen += $name
        if ($name -match $pattern -and ($AllowDisabled -or [WizardWindow]::IsWindowEnabled($h))) {
          Write-Host "Wizard [$step]: visible '$name' on $title"
          return $h
        }
      }
    }
    if ($process.HasExited) { throw "Wizard exited prematurely during $step (code $($process.ExitCode))" }
    Start-Sleep -Milliseconds 250
  } while ([datetime]::UtcNow -lt $deadline)
  throw "No matching control during $step. Last buttons: $($seen -join ', ')"
}
function Click-Button($pattern,$step) {
  [WizardWindow]::Click((Wait-Button $pattern $step)); Start-Sleep -Milliseconds 450
}
function Finish-Wizard {
  Click-Button '^Finish$' 'completion'
  if (-not $process.WaitForExit(30000) -or $process.ExitCode -notin @(0,3010)) { throw 'The interactive MSI failed to finish.' }
}
Open-Wizard 'interactive-install'
Click-Button '^Next$' 'welcome'
$accept = Wait-Button 'accept.*license' 'license agreement'
$next = Wait-Button '^Next$' 'license gate' -AllowDisabled
if ([WizardWindow]::IsWindowEnabled($next)) { throw 'License agreement was not required.' }
[WizardWindow]::Click($accept)
Click-Button '^Next$' 'accepted license'
[void](Wait-Button '^Change' 'destination chooser')
if ($Arch -eq 'arm64') {
  $wanted=(Join-Path $env:ProgramFiles 'Cryptomator').TrimEnd('\')
  $win=[WizardWindow]::Window($title)
  $paths=@([WizardWindow]::Controls($win) | ForEach-Object { [WizardWindow]::Label($_).TrimEnd('\') } | Where-Object { $_ -ieq $wanted })
  if (-not $paths.Count) { throw "Destination page does not show upstream default '$wanted'." }
  Write-Host "Verified visible ARM64 destination: $wanted"
}
Click-Button '^Next$' 'destination'
[void](Wait-Button 'Create a Start menu shortcut' 'shortcut choice')
Click-Button '^Next$' 'shortcut choice'
[void](Wait-Button '^Install$' 'ready')
Click-Button '^Back$' 'ready back'
[void](Wait-Button 'Create a Start menu shortcut' 'back to shortcuts')
Click-Button '^Next$' 'shortcut choice'
Click-Button '^Install$' 'install confirmation'
Finish-Wizard
$menu = [Environment]::GetFolderPath('CommonPrograms')
$link = Join-Path $menu $(if ($Arch -eq 'arm64') { 'Cryptomator.lnk' } else { "Cryptomator ($Arch).lnk" })
if (-not (Test-Path -LiteralPath $link)) { throw "Expected Start-menu shortcut not found: $link" }
Open-Wizard 'interactive-maintenance'
Click-Button '^Next$' 'maintenance welcome'
[void](Wait-Button '^Repair$' 'maintenance choices')
Click-Button '^Remove$' 'maintenance remove choice'
Click-Button '^Remove$' 'confirm removal'
Finish-Wizard
if (Test-Path -LiteralPath $link) { throw 'Uninstall left the shortcut behind.' }
Write-Host "Full visible MSI wizard and maintenance walk-through passed ($Arch)."
