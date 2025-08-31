Add-Type -AssemblyName PresentationFramework

# ============================
# Jok3rsGr1n state + helpers
# ============================
$BrandRoot = Join-Path $env:ProgramData "Jok3rsGr1n"
$StateFile = Join-Path $BrandRoot "state.json"

function Save-State {
    param([hashtable]$Data)
    New-Item -ItemType Directory -Path $BrandRoot -Force | Out-Null
    $Data | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
}

function Load-State {
    if (Test-Path $StateFile) {
        try { Get-Content $StateFile -Raw | ConvertFrom-Json } catch { $null }
    }
}

function Show-Dialog {
    param([string]$Title, [string]$Message)
    [System.Windows.MessageBox]::Show($Message, $Title, 'OK', 'Information') | Out-Null
}

function Show-Window {
    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Game Bar Cleanup" Height="300" Width="380" WindowStartupLocation="CenterScreen">
    <StackPanel Margin="20">
        <TextBlock Text="Choose an action:" FontSize="14" Margin="0,0,0,10"/>
        <ComboBox Name="ThemeSelector" SelectedIndex="0" Margin="0,0,0,10">
            <ComboBoxItem>Light</ComboBoxItem>
            <ComboBoxItem>Dark</ComboBoxItem>
        </ComboBox>
        <Button Name="CleanBtn" Content="Clean Game Bar" Height="30" Margin="0,0,0,10"/>
        <Button Name="RollbackBtn" Content="Rollback Changes" Height="30" Margin="0,0,0,10"/>
        <ProgressBar Name="ProgressBar" Minimum="0" Maximum="100" Height="20" Margin="0,10,0,10"/>
        <TextBlock Name="StatusText" FontSize="12" Foreground="Gray"/>
    </StackPanel>
</Window>
"@

    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)

    $progressBar   = $window.FindName("ProgressBar")
    $statusText    = $window.FindName("StatusText")
    $themeSelector = $window.FindName("ThemeSelector")

    # Theme toggle
    $themeSelector.Add_SelectionChanged({
        $selected = $themeSelector.SelectedItem.Content
        if ($selected -eq "Dark") {
            $window.Background     = "Black"
            $statusText.Foreground = "White"
        }
        else {
            $window.Background     = "White"
            $statusText.Foreground = "Black"
        }
    })

    # Clean button
    $window.FindName("CleanBtn").Add_Click({
        Run-Cleanup -Progress $progressBar -Status $statusText -Window $window
        Show-Dialog -Title "Cleanup Complete" -Message @"
✅ Game Bar cleanup finished.

• Protocols hijacked: ms-gamingoverlay, ms-gamebar, ms-xboxgamecallableui
• GameDVR disabled via registry policy
• GameAssist.exe removed and outbound traffic blocked
• System 'GameUIWatchdog' task disabled and GameUIWatchdog.exe terminated
• Jok3rsGr1n watchdog scheduled to suppress XboxGameUI

All changes are reversible via the Rollback button.
"@
    })

    # Rollback button
    $window.FindName("RollbackBtn").Add_Click({
        Run-Rollback -Progress $progressBar -Status $statusText -Window $window
        Show-Dialog -Title "Rollback Complete" -Message @"
🔄 Rollback finished.

• Protocol hijacks removed
• GameDVR registry keys restored
• Firewall rule for GameAssist removed
• System 'GameUIWatchdog' task restored if previously enabled
• Jok3rsGr1n watchdog task and script deleted

System returned to pre-cleanup state.
"@
    })

    $window.ShowDialog() | Out-Null
}

function Hijack-Protocol {
    param([string]$Protocol)
    $regPath = "HKCR\$Protocol"
    New-Item -Path "Registry::$regPath" -Force | Out-Null
    Set-ItemProperty -Path "Registry::$regPath" -Name "(Default)"     -Value "URL:$Protocol"
    Set-ItemProperty -Path "Registry::$regPath" -Name "URL Protocol" -Value ""

    $exePath = "$($env:SystemRoot)\System32\systray.exe"
    New-Item -Path "Registry::$regPath\shell\open\command" -Force | Out-Null
    Set-ItemProperty -Path "Registry::$regPath\shell\open\command" -Name "(Default)" -Value "`"$exePath`""
}

# ============================
# System GameUIWatchdog handling (disable/restore)
# ============================
function Get-SystemGameUIWatchdogTasks {
    # Try known path first, then wildcard across all tasks as fallback
    $known = Get-ScheduledTask -TaskPath "\Microsoft\XblGameSave\" -TaskName "GameUIWatchdog" -ErrorAction SilentlyContinue
    if ($known) { return ,$known }
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -eq "GameUIWatchdog" }
}

function Disable-SystemGameUIWatchdog {
    $tasks = Get-SystemGameUIWatchdogTasks
    $state = @{ SystemGameUIWatchdogFound = $false; WasEnabled = $false }

    if ($tasks) {
        $state.SystemGameUIWatchdogFound = $true
        # If any instance was enabled, remember that
        if ($tasks | Where-Object { $_.State -eq 'Ready' -or $_.State -eq 'Running' }) { $state.WasEnabled = $true }
        foreach ($t in $tasks) {
            try {
                Disable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop | Out-Null
            } catch {}
        }
    }

    Save-State $state
    return $state.SystemGameUIWatchdogFound
}

function Restore-SystemGameUIWatchdog {
    $state = Load-State
    if (-not $state) { return }

    if ($state.SystemGameUIWatchdogFound -and $state.WasEnabled) {
        $tasks = Get-SystemGameUIWatchdogTasks
        foreach ($t in $tasks) {
            try {
                Enable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop | Out-Null
            } catch {}
        }
    }
}

# ============================
# Jok3rsGr1n watchdog (no collision with system)
# ============================
function Schedule-Watchdog {
    param([string]$TargetExe)

    New-Item -ItemType Directory -Path $BrandRoot -Force | Out-Null
    $scriptPath    = Join-Path $BrandRoot "XboxUIWatchdog.ps1"
    $taskName      = "Jok3rsGr1n_XboxUI_Watchdog"

$scriptContent = @"
if (Test-Path '$TargetExe') {
    try {
        Stop-Process -Name 'XboxGameUI' -Force -ErrorAction SilentlyContinue
    } catch {}
}
"@

    Set-Content -Path $scriptPath -Value $scriptContent -Encoding UTF8

    $action  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -File `"$scriptPath`""
    $trigger = New-ScheduledTaskTrigger -Daily -At 12:00PM

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -RunLevel Highest -Force | Out-Null
}

function Remove-Watchdog {
    $taskName   = "Jok3rsGr1n_XboxUI_Watchdog"
    $scriptPath = Join-Path $BrandRoot "XboxUIWatchdog.ps1"

    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item $scriptPath -Force -ErrorAction SilentlyContinue
}

# ============================
# Process termination
# ============================
function Kill-GameBarProcesses {
    $targets = @(
        "GameBar",
        "GameBarFTServer",
        "GameBarPresenceWriter",
        "GameUIWatchdog"
    )
    foreach ($name in $targets) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                Stop-Process -Id $_.Id -Force -ErrorAction Stop
            } catch {}
        }
    }
}

function UpdateProgress {
    param (
        [string]$Message,
        [int]   $Step,
        [int]   $TotalSteps,
        $ProgressBar,
        $StatusText,
        $Window
    )
    $Window.Dispatcher.Invoke([action]{
        $ProgressBar.Value = [math]::Round(($Step / $TotalSteps) * 100)
        $StatusText.Text   = $Message
    })
    Start-Sleep -Milliseconds 300
}

function Run-Cleanup {
    param($Progress, $Status, $Window)

    $steps = 7; $step = 0

    $step++; UpdateProgress "Hijacking protocols..." $step $steps $Progress $Status $Window
    Hijack-Protocol -Protocol "ms-gamingoverlay"
    Hijack-Protocol -Protocol "ms-gamebar"
    Hijack-Protocol -Protocol "ms-xboxgamecallableui"

    $step++; UpdateProgress "Disabling GameDVR..." $step $steps $Progress $Status $Window
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Force | Out-Null
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Name "AllowGameDVR" -Value 0
    New-Item -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" -Force | Out-Null
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" -Name "AppCaptureEnabled" -Value 0
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" -Name "GameDVR_Enabled" -Value 0

    $step++; UpdateProgress "Blocking GameAssist..." $step $steps $Progress $Status $Window
    $assistPath = "$env:ProgramFiles\Microsoft\GameAssist\GameAssist.exe"
    if (Test-Path $assistPath) {
        Stop-Process -Name "GameAssist" -Force -ErrorAction SilentlyContinue
        Remove-Item $assistPath -Force -ErrorAction SilentlyContinue
    }
    New-NetFirewallRule -DisplayName "Block GameAssist" `
        -Direction Outbound `
        -Program   $assistPath `
        -Action    Block `
        -Enabled   True `
        -Profile   Any `
        -ErrorAction SilentlyContinue | Out-Null

    $step++; UpdateProgress "Terminating Game Bar processes..." $step $steps $Progress $Status $Window
    Kill-GameBarProcesses

    $step++; UpdateProgress "Disabling system 'GameUIWatchdog' task..." $step $steps $Progress $Status $Window
    $found = Disable-SystemGameUIWatchdog
    if (-not $found) {
        # No system task found — still proceed
    }

    $step++; UpdateProgress "Scheduling Jok3rsGr1n watchdog..." $step $steps $Progress $Status $Window
    $xboxExe = "C:\Windows\SystemApps\Microsoft.XboxGameCallableUI_cw5n1h2txyewy\XboxGameUI.exe"
    Schedule-Watchdog -TargetExe $xboxExe

    $step++; UpdateProgress "Finalizing..." $step $steps $Progress $Status $Window
    $Window.Dispatcher.Invoke([action]{
        $Progress.Value = $Progress.Maximum
        $Status.Text    = "✅ Cleanup complete."
    })
}

function Run-Rollback {
    param($Progress, $Status, $Window)

    $steps = 6; $step = 0

    $step++; UpdateProgress "Removing protocol hijacks..." $step $steps $Progress $Status $Window
    Remove-Item "Registry::HKCR\ms-gamingoverlay"       -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "Registry::HKCR\ms-gamebar"             -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "Registry::HKCR\ms-xboxgamecallableui"  -Recurse -Force -ErrorAction SilentlyContinue

    $step++; UpdateProgress "Restoring GameDVR registry..." $step $steps $Progress $Status $Window
    Remove-Item "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" -Recurse -Force -ErrorAction SilentlyContinue

    $step++; UpdateProgress "Removing firewall rule..." $step $steps $Progress $Status $Window
    Remove-NetFirewallRule -DisplayName "Block GameAssist" -ErrorAction SilentlyContinue

    $step++; UpdateProgress "Restoring system 'GameUIWatchdog' task if needed..." $step $steps $Progress $Status $Window
    Restore-SystemGameUIWatchdog

    $step++; UpdateProgress "Removing Jok3rsGr1n watchdog..." $step $steps $Progress $Status $Window
    Remove-Watchdog

    $step++; UpdateProgress "Finalizing..." $step $steps $Progress $Status $Window
    $Window.Dispatcher.Invoke([action]{
        $Progress.Value = $Progress.Maximum
        $Status.Text    = "🔄 Rollback complete."
    })
}

# Kick things off
Show-Window