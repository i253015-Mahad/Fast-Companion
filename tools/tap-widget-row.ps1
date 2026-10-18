<#
.SYNOPSIS
  Taps a home-screen widget row by its visible text, and reports what the
  widget showed before and after.

  Tapping by hard-coded coordinates was unreliable: the row list shifts as
  items are ticked and the checked section expands, so the same coordinate
  silently starts hitting a different row. Reading the bounds out of the UI
  dump removes that guesswork entirely.

.EXAMPLE
  .\tools\tap-widget-row.ps1 -Text 'Coal lab'
#>
param(
  [Parameter(Mandatory = $true)] [string] $Text,
  [int] $Retries = 12
)

$ErrorActionPreference = 'Stop'
$A = 'D:\Mahad\SDKs\Android\platform-tools\adb.exe'

function Get-UiText {
  & $A shell uiautomator dump /sdcard/ui.xml 2>&1 | Out-Null
  return ((& $A shell cat /sdcard/ui.xml) -join '')
}

function Get-WidgetState([string] $xml) {
  if ($xml -match 'Imp Notes') { return 'NOTE' }
  if ($xml -match 'Fast Companion') { return 'PLACEHOLDER' }
  return 'NO-WIDGET'
}

function Find-RowBounds([string] $xml, [string] $needle) {
  foreach ($m in [regex]::Matches($xml, 'text="([^"]*)"[^>]*?bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"')) {
    if ($m.Groups[1].Value -like "*$needle*") {
      $x = ([int]$m.Groups[2].Value + [int]$m.Groups[4].Value) / 2
      $y = ([int]$m.Groups[3].Value + [int]$m.Groups[5].Value) / 2
      return @($x, $y, $m.Groups[1].Value)
    }
  }
  return $null
}

# Get to a home-screen page that actually holds the widget.
& $A shell input keyevent KEYCODE_WAKEUP 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
& $A shell input keyevent KEYCODE_HOME 2>&1 | Out-Null
Start-Sleep -Milliseconds 1500

$xml = ''
for ($i = 1; $i -le $Retries; $i++) {
  $xml = Get-UiText
  if ((Get-WidgetState $xml) -ne 'NO-WIDGET') { break }
  & $A shell input swipe 900 1300 120 1300 900 2>&1 | Out-Null
  Start-Sleep -Milliseconds 1200
}

$before = Get-WidgetState $xml
if ($before -eq 'NO-WIDGET') {
  Write-Output "RESULT: could not find the widget after $Retries pages"
  exit 1
}

$hit = Find-RowBounds $xml $Text
if (-not $hit) {
  Write-Output "RESULT: '$Text' is not on screen (widget shows $before)"
  Write-Output '--- rows visible ---'
  [regex]::Matches($xml, 'text="([^"]+)"[^>]*?bounds="\[\d+,\d+\]\[\d+,\d+\]"') |
    ForEach-Object { '   ' + $_.Groups[1].Value } | Select-Object -First 12
  exit 1
}

& $A shell logcat -c 2>&1 | Out-Null
& $A shell input tap $hit[0] $hit[1] 2>&1 | Out-Null

Write-Output ("TAPPED: '{0}' at ({1},{2})  widget before = {3}" -f $hit[2], $hit[0], $hit[1], $before)

# The tap has to boot Dart, save, let the launcher drop our views and then let
# the redraw put them back — about two seconds end to end on this device, so
# read the widget well after that rather than immediately.
Start-Sleep -Seconds 4
$after = Get-WidgetState (Get-UiText)
Write-Output ("RESULT: widget before = {0}, after = {1}" -f $before, $after)

if ($before -eq 'NOTE' -and $after -ne 'NOTE') {
  Write-Output "STRANDED: the launcher's drop was not answered - this is the bug"
  exit 2
}
Write-Output 'OK: widget still shows the note'
