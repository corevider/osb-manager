param(
    [string]$Archive = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\OSB-Manager-windows-x64.zip'),
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
Add-Type -Namespace Native -Name Windows -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr window, uint command);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr window, System.Text.StringBuilder text, int maximum);
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
public delegate bool EnumChildProc(IntPtr window, IntPtr parameter);
[DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumChildProc callback, IntPtr parameter);
'@

$work = Join-Path $env:TEMP ('OsbManager-package-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$unpacked = Join-Path $work 'unpacked'
$dataFolder = Join-Path $work 'data'
New-Item -ItemType Directory -Force -Path $unpacked, $dataFolder | Out-Null
Expand-Archive -LiteralPath $Archive -DestinationPath $unpacked

foreach ($required in 'OsbManager.exe', 'README.md', 'LICENSE') {
    if (-not (Test-Path -LiteralPath (Join-Path $unpacked $required))) {
        throw "The archive has no $required."
    }
}

function Wait-For([scriptblock]$Probe, [string]$What) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $found = & $Probe
        if ($found) {
            return $found
        }
        Start-Sleep -Milliseconds 300
    }
    throw "Timed out waiting for $What."
}

function Get-WindowText([IntPtr]$Window) {
    $text = New-Object Text.StringBuilder 512
    [void][Native.Windows]::GetWindowText($Window, $text, 512)
    $text.ToString()
}

function Get-Dialog([IntPtr]$Owner, [string]$Title) {
    $dialog = [Native.Windows]::GetWindow($Owner, 6)
    if ($dialog -ne [IntPtr]::Zero -and (Get-WindowText $dialog) -eq $Title) {
        $dialog
    }
}

function Get-ChildTexts([IntPtr]$Parent) {
    $texts = New-Object Collections.Generic.List[string]
    $callback = [Native.Windows+EnumChildProc]{ param($window, $parameter) $value = Get-WindowText $window; if ($value) { $texts.Add($value) }; $true }
    [void][Native.Windows]::EnumChildWindows($Parent, $callback, [IntPtr]::Zero)
    $texts
}

$process = Start-Process -FilePath (Join-Path $unpacked 'OsbManager.exe') -ArgumentList '--data', "`"$dataFolder`"" -PassThru
$opener = $null
try {
    Wait-For { $process.Refresh(); if ($process.HasExited) { throw 'OSB Manager exited at startup.' }; $process.MainWindowHandle -ne [IntPtr]::Zero } 'the main window' | Out-Null
    $mainHandle = $process.MainWindowHandle
    Write-Host "Main window: $($process.MainWindowTitle)"

    $opener = Start-Job -ArgumentList $mainHandle.ToInt64() -ScriptBlock {
        param($handle)
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
        $window = [Windows.Automation.AutomationElement]::FromHandle([IntPtr][long]$handle)
        $find = {
            param($parent, $name)
            for ($attempt = 0; $attempt -lt 40; $attempt++) {
                $item = $parent.FindFirst([Windows.Automation.TreeScope]::Descendants, (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NameProperty, $name)))
                if ($item) { return $item }
                Start-Sleep -Milliseconds 500
            }
        }
        $help = & $find $window 'Help'
        $help.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
        $about = & $find $help 'About'
        try {
            $about.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
        }
        catch [Runtime.InteropServices.COMException] {
        }
    }

    $aboutTitle = 'About OSB Manager'
    $dialog = Wait-For { Get-Dialog $mainHandle $aboutTitle } 'the About box'
    $texts = @(Get-ChildTexts $dialog)
    Write-Host "About box: $($texts -join ' | ')"
    if (-not ($texts -contains 'OSB Manager')) {
        throw 'The About box does not show the app name.'
    }
    [void][Native.Windows]::PostMessage($dialog, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
    Wait-For { -not (Get-Dialog $mainHandle $aboutTitle) } 'the About box to close' | Out-Null

    $accounts = Join-Path $dataFolder 'accounts.json'
    if (Test-Path -LiteralPath $accounts) {
        $content = Get-Content -LiteralPath $accounts -Raw
        if ($content -match '"loginId"\s*:\s*"[^"]') {
            throw 'The test data folder holds a login ID.'
        }
    }

    $null = $process.CloseMainWindow()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        throw 'OSB Manager did not close.'
    }
    Write-Host "PASS: started, showed the About box, closed (exit code $($process.ExitCode))."
}
finally {
    if (-not $process.HasExited) {
        $process.Kill()
    }
    if ($opener) {
        Remove-Job $opener -Force
    }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
