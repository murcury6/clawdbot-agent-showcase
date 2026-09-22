param(
  [string]$BasePath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$BasePath = (Resolve-Path $BasePath).Path
$stateDir = Join-Path $BasePath "state\.openclaw"
$modePath = Join-Path $stateDir "model-mode.txt"
$selectionPath = Join-Path $stateDir "model-selection.json"
$workspacePath = Join-Path $BasePath "workspace"
$logsPath = Join-Path $BasePath "logs"
$rootPath = Split-Path -Parent $BasePath

function Get-PortableMode {
  if (Test-Path $modePath) {
    return ((Get-Content $modePath -Raw).Trim())
  }

  return "auto"
}

function Set-PortableMode {
  param([string]$Mode)

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $BasePath "scripts\select-model.ps1") -BasePath $BasePath -SetMode $Mode | Out-Null
}

function Get-PortStatus {
  param([int]$Port)

  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $async = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
    $ok = $async.AsyncWaitHandle.WaitOne(400)
    if ($ok -and $client.Connected) {
      $client.EndConnect($async) | Out-Null
      return "up"
    }
  } catch {
  } finally {
    $client.Close()
  }

  return "down"
}

function Get-SelectionSummary {
  if (-not (Test-Path $selectionPath)) {
    return "No model-selection.json yet. Use Start or Apply Mode first."
  }

  try {
    $selection = Get-Content $selectionPath -Raw | ConvertFrom-Json
    $lines = @(
      ("Mode: " + $selection.mode),
      ("Routine model: " + $selection.roles.routine),
      ("Telegram model: " + $selection.roles.telegramDirect),
      ("Hard-task model: " + $selection.roles.hardTask),
      ("Cloud reachable: " + $selection.cloudReachable),
      ("RAM total/free GiB: " + $selection.totalMemoryGiB + " / " + $selection.freeMemoryGiB),
      ("Reason: " + $selection.reason)
    )
    return ($lines -join [Environment]::NewLine)
  } catch {
    return "Unable to read model selection."
  }
}

function Invoke-RootLauncher {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FileName
  )

  $target = Join-Path $rootPath $FileName
  if (-not (Test-Path $target)) {
    [System.Windows.Forms.MessageBox]::Show("Missing launcher: $target", "ClawdBot Control Center") | Out-Null
    return
  }

  Start-Process -FilePath $target -WorkingDirectory $rootPath | Out-Null
}

function Open-PathIfExists {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if (Test-Path $Path) {
    Start-Process explorer.exe $Path | Out-Null
  } else {
    [System.Windows.Forms.MessageBox]::Show("Path not found: $Path", "ClawdBot Control Center") | Out-Null
  }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "ClawdBot Control Center"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(760, 520)
$form.MinimumSize = New-Object System.Drawing.Size(760, 520)
$form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)

$title = New-Object System.Windows.Forms.Label
$title.Text = "ClawdBot Control Center"
$title.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 18)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(18, 14)
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = "Start the bot, switch model strategy, and manage the SSD install from one place."
$subtitle.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$subtitle.AutoSize = $true
$subtitle.Location = New-Object System.Drawing.Point(20, 48)
$form.Controls.Add($subtitle)

$modeLabel = New-Object System.Windows.Forms.Label
$modeLabel.Text = "Model mode"
$modeLabel.AutoSize = $true
$modeLabel.Location = New-Object System.Drawing.Point(22, 88)
$form.Controls.Add($modeLabel)

$modeBox = New-Object System.Windows.Forms.ComboBox
$modeBox.DropDownStyle = "DropDownList"
$modeBox.Items.AddRange(@("auto", "smart-cost", "online-first", "offline-first"))
$modeBox.Location = New-Object System.Drawing.Point(22, 110)
$modeBox.Size = New-Object System.Drawing.Size(180, 30)
$form.Controls.Add($modeBox)

$applyModeButton = New-Object System.Windows.Forms.Button
$applyModeButton.Text = "Apply Mode"
$applyModeButton.Location = New-Object System.Drawing.Point(214, 108)
$applyModeButton.Size = New-Object System.Drawing.Size(110, 30)
$form.Controls.Add($applyModeButton)

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = "Refresh"
$refreshButton.Location = New-Object System.Drawing.Point(336, 108)
$refreshButton.Size = New-Object System.Drawing.Size(90, 30)
$form.Controls.Add($refreshButton)

$startButton = New-Object System.Windows.Forms.Button
$startButton.Text = "Start Bot"
$startButton.Location = New-Object System.Drawing.Point(22, 160)
$startButton.Size = New-Object System.Drawing.Size(140, 38)
$form.Controls.Add($startButton)

$chatButton = New-Object System.Windows.Forms.Button
$chatButton.Text = "Chat"
$chatButton.Location = New-Object System.Drawing.Point(176, 160)
$chatButton.Size = New-Object System.Drawing.Size(110, 38)
$form.Controls.Add($chatButton)

$checkButton = New-Object System.Windows.Forms.Button
$checkButton.Text = "Check Status"
$checkButton.Location = New-Object System.Drawing.Point(300, 160)
$checkButton.Size = New-Object System.Drawing.Size(126, 38)
$form.Controls.Add($checkButton)

$stopButton = New-Object System.Windows.Forms.Button
$stopButton.Text = "Stop"
$stopButton.Location = New-Object System.Drawing.Point(440, 160)
$stopButton.Size = New-Object System.Drawing.Size(100, 38)
$form.Controls.Add($stopButton)

$settingsButton = New-Object System.Windows.Forms.Button
$settingsButton.Text = "Settings"
$settingsButton.Location = New-Object System.Drawing.Point(554, 160)
$settingsButton.Size = New-Object System.Drawing.Size(100, 38)
$form.Controls.Add($settingsButton)

$freshButton = New-Object System.Windows.Forms.Button
$freshButton.Text = "Fresh Start"
$freshButton.Location = New-Object System.Drawing.Point(22, 214)
$freshButton.Size = New-Object System.Drawing.Size(140, 34)
$form.Controls.Add($freshButton)

$workspaceButton = New-Object System.Windows.Forms.Button
$workspaceButton.Text = "Open Workspace"
$workspaceButton.Location = New-Object System.Drawing.Point(176, 214)
$workspaceButton.Size = New-Object System.Drawing.Size(140, 34)
$form.Controls.Add($workspaceButton)

$logsButton = New-Object System.Windows.Forms.Button
$logsButton.Text = "Open Logs"
$logsButton.Location = New-Object System.Drawing.Point(330, 214)
$logsButton.Size = New-Object System.Drawing.Size(110, 34)
$form.Controls.Add($logsButton)

$rootButton = New-Object System.Windows.Forms.Button
$rootButton.Text = "Open SSD Root"
$rootButton.Location = New-Object System.Drawing.Point(454, 214)
$rootButton.Size = New-Object System.Drawing.Size(120, 34)
$form.Controls.Add($rootButton)

$keysButton = New-Object System.Windows.Forms.Button
$keysButton.Text = "Open Keys"
$keysButton.Location = New-Object System.Drawing.Point(588, 214)
$keysButton.Size = New-Object System.Drawing.Size(100, 34)
$form.Controls.Add($keysButton)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "Bot status"
$statusLabel.AutoSize = $true
$statusLabel.Location = New-Object System.Drawing.Point(22, 270)
$form.Controls.Add($statusLabel)

$statusBox = New-Object System.Windows.Forms.TextBox
$statusBox.Location = New-Object System.Drawing.Point(22, 292)
$statusBox.Multiline = $true
$statusBox.ReadOnly = $true
$statusBox.ScrollBars = "Vertical"
$statusBox.Font = New-Object System.Drawing.Font("Consolas", 10)
$statusBox.Size = New-Object System.Drawing.Size(700, 170)
$form.Controls.Add($statusBox)

$hint = New-Object System.Windows.Forms.Label
$hint.Text = "Tip: smart-cost is the best default for easy management. It keeps routine work cheaper and safer."
$hint.AutoSize = $true
$hint.Location = New-Object System.Drawing.Point(22, 470)
$form.Controls.Add($hint)

function Refresh-UiState {
  $modeBox.SelectedItem = $null
  $modeBox.Text = ""
  [void]$modeBox.Items.IndexOf((Get-PortableMode))
  $currentMode = Get-PortableMode
  if ($modeBox.Items.Contains($currentMode)) {
    $modeBox.SelectedItem = $currentMode
  }

  $ollamaPort = Get-PortStatus -Port 11500
  $gatewayPort = Get-PortStatus -Port 18789
  $statusLines = @(
    ("Ollama port 11500: " + $ollamaPort),
    ("Gateway port 18789: " + $gatewayPort),
    "",
    (Get-SelectionSummary)
  )
  $statusBox.Text = ($statusLines -join [Environment]::NewLine)
}

$applyModeButton.Add_Click({
  if (-not $modeBox.SelectedItem) {
    [System.Windows.Forms.MessageBox]::Show("Choose a model mode first.", "ClawdBot Control Center") | Out-Null
    return
  }

  try {
    Set-PortableMode -Mode ([string]$modeBox.SelectedItem)
    Refresh-UiState
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "ClawdBot Control Center") | Out-Null
  }
})

$refreshButton.Add_Click({ Refresh-UiState })
$startButton.Add_Click({ Invoke-RootLauncher -FileName "1 - Start Bot.bat" })
$chatButton.Add_Click({ Invoke-RootLauncher -FileName "2 - Chat With Bot.bat" })
$checkButton.Add_Click({ Invoke-RootLauncher -FileName "3 - Check Bot.bat" })
$stopButton.Add_Click({ Invoke-RootLauncher -FileName "4 - Stop Bot.bat" })
$settingsButton.Add_Click({ Invoke-RootLauncher -FileName "5 - Settings.bat" })
$freshButton.Add_Click({ Invoke-RootLauncher -FileName "6 - Fresh Start Bot.bat" })
$workspaceButton.Add_Click({ Open-PathIfExists -Path $workspacePath })
$logsButton.Add_Click({ Open-PathIfExists -Path $logsPath })
$rootButton.Add_Click({ Open-PathIfExists -Path $rootPath })
$keysButton.Add_Click({ Open-PathIfExists -Path (Join-Path $BasePath "clawdkeys") })

Refresh-UiState
[void]$form.ShowDialog()
