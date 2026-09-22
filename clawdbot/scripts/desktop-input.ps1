param(
  [Parameter(Position = 0, Mandatory = $true)]
  [string]$Action,
  [Parameter(Position = 1)]
  [string]$Arg1,
  [Parameter(Position = 2)]
  [string]$Arg2,
  [Parameter(Position = 3)]
  [string]$Arg3,
  [Parameter(Position = 4)]
  [string]$Arg4
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class DesktopInputNative {
  [StructLayout(LayoutKind.Sequential)]
  public struct POINT {
    public int X;
    public int Y;
  }

  [DllImport("user32.dll")]
  public static extern bool GetCursorPos(out POINT lpPoint);

  [DllImport("user32.dll")]
  public static extern bool SetCursorPos(int X, int Y);

  [DllImport("user32.dll")]
  public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
}
"@

$LeftDown = 0x0002
$LeftUp = 0x0004
$RightDown = 0x0008
$RightUp = 0x0010
$MiddleDown = 0x0020
$MiddleUp = 0x0040
$Wheel = 0x0800

function Get-CursorPosition {
  $point = New-Object DesktopInputNative+POINT
  [DesktopInputNative]::GetCursorPos([ref]$point) | Out-Null
  [pscustomobject]@{
    x = $point.X
    y = $point.Y
  }
}

function Move-Cursor {
  param(
    [int]$X,
    [int]$Y
  )

  [DesktopInputNative]::SetCursorPos($X, $Y) | Out-Null
  Start-Sleep -Milliseconds 30
}

function Invoke-MouseClick {
  param(
    [ValidateSet("left", "right", "middle")]
    [string]$Button = "left"
  )

  switch ($Button) {
    "left" {
      [DesktopInputNative]::mouse_event($LeftDown, 0, 0, 0, [UIntPtr]::Zero)
      [DesktopInputNative]::mouse_event($LeftUp, 0, 0, 0, [UIntPtr]::Zero)
    }
    "right" {
      [DesktopInputNative]::mouse_event($RightDown, 0, 0, 0, [UIntPtr]::Zero)
      [DesktopInputNative]::mouse_event($RightUp, 0, 0, 0, [UIntPtr]::Zero)
    }
    "middle" {
      [DesktopInputNative]::mouse_event($MiddleDown, 0, 0, 0, [UIntPtr]::Zero)
      [DesktopInputNative]::mouse_event($MiddleUp, 0, 0, 0, [UIntPtr]::Zero)
    }
  }
}

function Invoke-MouseDown {
  param(
    [ValidateSet("left", "right", "middle")]
    [string]$Button = "left"
  )

  switch ($Button) {
    "left" { [DesktopInputNative]::mouse_event($LeftDown, 0, 0, 0, [UIntPtr]::Zero) }
    "right" { [DesktopInputNative]::mouse_event($RightDown, 0, 0, 0, [UIntPtr]::Zero) }
    "middle" { [DesktopInputNative]::mouse_event($MiddleDown, 0, 0, 0, [UIntPtr]::Zero) }
  }
}

function Invoke-MouseUp {
  param(
    [ValidateSet("left", "right", "middle")]
    [string]$Button = "left"
  )

  switch ($Button) {
    "left" { [DesktopInputNative]::mouse_event($LeftUp, 0, 0, 0, [UIntPtr]::Zero) }
    "right" { [DesktopInputNative]::mouse_event($RightUp, 0, 0, 0, [UIntPtr]::Zero) }
    "middle" { [DesktopInputNative]::mouse_event($MiddleUp, 0, 0, 0, [UIntPtr]::Zero) }
  }
}

function Escape-SendKeysLiteral {
  param([string]$Text)

  $builder = New-Object System.Text.StringBuilder
  foreach ($ch in $Text.ToCharArray()) {
    switch ($ch) {
      '+' { [void]$builder.Append('{+}') }
      '^' { [void]$builder.Append('{^}') }
      '%' { [void]$builder.Append('{%}') }
      '~' { [void]$builder.Append('{~}') }
      '(' { [void]$builder.Append('{(}') }
      ')' { [void]$builder.Append('{)}') }
      '{' { [void]$builder.Append('{{}') }
      '}' { [void]$builder.Append('{}}') }
      '[' { [void]$builder.Append('{[}') }
      ']' { [void]$builder.Append('{]}') }
      default { [void]$builder.Append($ch) }
    }
  }
  $builder.ToString()
}

function Convert-KeyToken {
  param([string]$Token)

  $upper = $Token.Trim().ToUpperInvariant()
  switch ($upper) {
    "ENTER" { "{ENTER}" }
    "TAB" { "{TAB}" }
    "ESC" { "{ESC}" }
    "ESCAPE" { "{ESC}" }
    "SPACE" { " " }
    "BACKSPACE" { "{BACKSPACE}" }
    "DELETE" { "{DELETE}" }
    "DEL" { "{DELETE}" }
    "INSERT" { "{INSERT}" }
    "HOME" { "{HOME}" }
    "END" { "{END}" }
    "PGUP" { "{PGUP}" }
    "PAGEUP" { "{PGUP}" }
    "PGDN" { "{PGDN}" }
    "PAGEDOWN" { "{PGDN}" }
    "UP" { "{UP}" }
    "DOWN" { "{DOWN}" }
    "LEFT" { "{LEFT}" }
    "RIGHT" { "{RIGHT}" }
    "F1" { "{F1}" }
    "F2" { "{F2}" }
    "F3" { "{F3}" }
    "F4" { "{F4}" }
    "F5" { "{F5}" }
    "F6" { "{F6}" }
    "F7" { "{F7}" }
    "F8" { "{F8}" }
    "F9" { "{F9}" }
    "F10" { "{F10}" }
    "F11" { "{F11}" }
    "F12" { "{F12}" }
    default {
      Escape-SendKeysLiteral $Token
    }
  }
}

function Convert-ToSendKeys {
  param([string]$Keys)

  if ([string]::IsNullOrWhiteSpace($Keys)) {
    throw "Missing key sequence."
  }

  $parts = @($Keys -split '\+')
  if ($parts.Count -eq 1) {
    return (Convert-KeyToken $parts[0])
  }

  $modifiers = ""
  for ($idx = 0; $idx -lt $parts.Count - 1; $idx++) {
    switch ($parts[$idx].Trim().ToUpperInvariant()) {
      "CTRL" { $modifiers += "^" }
      "CONTROL" { $modifiers += "^" }
      "ALT" { $modifiers += "%" }
      "SHIFT" { $modifiers += "+" }
      default { throw "Unsupported modifier: $($parts[$idx])" }
    }
  }

  $keyToken = Convert-KeyToken $parts[$parts.Count - 1]
  if ($keyToken.StartsWith("{")) {
    return $modifiers + $keyToken
  }
  return $modifiers + "(" + $keyToken + ")"
}

function Write-Position {
  (Get-CursorPosition) | ConvertTo-Json -Compress
}

$normalized = $Action.Trim().ToLowerInvariant()
switch ($normalized) {
  "position" {
    Write-Position
  }
  "move" {
    if ($null -eq $Arg1 -or $null -eq $Arg2) {
      throw "Usage: move X Y"
    }
    Move-Cursor -X ([int]$Arg1) -Y ([int]$Arg2)
    Write-Position
  }
  "click" {
    $button = if ($Arg1) { $Arg1.ToLowerInvariant() } else { "left" }
    if ($Arg2 -and $Arg3) {
      Move-Cursor -X ([int]$Arg2) -Y ([int]$Arg3)
    }
    Invoke-MouseClick -Button $button
    Write-Position
  }
  "doubleclick" {
    $button = if ($Arg1) { $Arg1.ToLowerInvariant() } else { "left" }
    if ($Arg2 -and $Arg3) {
      Move-Cursor -X ([int]$Arg2) -Y ([int]$Arg3)
    }
    Invoke-MouseClick -Button $button
    Start-Sleep -Milliseconds 70
    Invoke-MouseClick -Button $button
    Write-Position
  }
  "drag" {
    if ($null -eq $Arg1 -or $null -eq $Arg2 -or $null -eq $Arg3 -or $null -eq $Arg4) {
      throw "Usage: drag X1 Y1 X2 Y2"
    }
    $x1 = [int]$Arg1
    $y1 = [int]$Arg2
    $x2 = [int]$Arg3
    $y2 = [int]$Arg4
    Move-Cursor -X $x1 -Y $y1
    Invoke-MouseDown -Button left
    $steps = 12
    for ($step = 1; $step -le $steps; $step++) {
      $x = [int]([math]::Round($x1 + (($x2 - $x1) * $step / $steps)))
      $y = [int]([math]::Round($y1 + (($y2 - $y1) * $step / $steps)))
      Move-Cursor -X $x -Y $y
      Start-Sleep -Milliseconds 15
    }
    Invoke-MouseUp -Button left
    Write-Position
  }
  "scroll" {
    if ($null -eq $Arg1) {
      throw "Usage: scroll DELTA"
    }
    [DesktopInputNative]::mouse_event($Wheel, 0, 0, [uint32]([int]$Arg1), [UIntPtr]::Zero)
    Write-Position
  }
  "type" {
    if ([string]::IsNullOrEmpty($Arg1)) {
      throw "Usage: type ""text"""
    }
    [System.Windows.Forms.SendKeys]::SendWait((Escape-SendKeysLiteral $Arg1))
    "OK"
  }
  "key" {
    if ([string]::IsNullOrEmpty($Arg1)) {
      throw "Usage: key ""CTRL+S"""
    }
    [System.Windows.Forms.SendKeys]::SendWait((Convert-ToSendKeys $Arg1))
    "OK"
  }
  default {
    throw "Unsupported action: $Action"
  }
}
