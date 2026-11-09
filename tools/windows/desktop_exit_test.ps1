param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$debugRoot = Join-Path $projectRoot 'artifacts\windows-debug'
$buildInfo = Get-Content -LiteralPath (Join-Path $debugRoot 'build-info.json') -Raw | ConvertFrom-Json
$binary = Join-Path $debugRoot 'source\build\windows\x64\runner\Debug\baha_plus.exe'
$kernel = Join-Path (Split-Path -Parent $binary) 'data\flutter_assets\kernel_blob.bin'
$webViewPlugin = Join-Path (Split-Path -Parent $binary) 'flutter_inappwebview_windows_plugin.dll'
if ($buildInfo.entrypoint -ne 'lib/desktop_main.dart' -or
    (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash -ne $buildInfo.executableSha256 -or
    (Get-FileHash -LiteralPath $kernel -Algorithm SHA256).Hash -ne $buildInfo.dartKernelSha256 -or
    (Get-FileHash -LiteralPath $webViewPlugin -Algorithm SHA256).Hash -ne $buildInfo.webViewPluginSha256) {
    throw 'Build the ordinary desktop entrypoint before testing window exit.'
}
$existing = @(Get-Process -Name baha_plus -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -eq $binary
})
if ($existing.Count -gt 0) {
    throw 'The built Baha Plus application is already running. Inspect that instance before starting exit tests.'
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BahaDesktopExitTestNative {
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
}
'@

$results = @()
foreach ($scenario in @('normal', 'minimized')) {
    $stdout = Join-Path $debugRoot "exit-$scenario.log"
    $stderr = Join-Path $debugRoot "exit-$scenario-errors.log"
    $started = Get-Date
    $app = Start-Process -FilePath $binary -WorkingDirectory (Split-Path -Parent $binary) `
        -WindowStyle Normal -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    $deadline = $started.AddSeconds(120)
    while (-not $app.HasExited -and $app.MainWindowHandle -eq 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
        $app.Refresh()
    }
    if ($app.HasExited -or $app.MainWindowHandle -eq 0) {
        throw "Baha Plus did not show its main window for scenario '$scenario'. See $stdout and $stderr."
    }
    $window = $app.MainWindowHandle
    [BahaDesktopExitTestNative]::ShowWindow($window, 9) | Out-Null
    # Allow the actual app and its WebView2 session to initialize before closing.
    Start-Sleep -Seconds 10
    if ($scenario -eq 'minimized') {
        [BahaDesktopExitTestNative]::ShowWindow($window, 6) | Out-Null
        if (-not [BahaDesktopExitTestNative]::IsIconic($window)) {
            throw 'The operating system did not minimize the Baha Plus window.'
        }
        # The exit callback below records the actual Flutter lifecycle state;
        # an already-hidden window need not emit a duplicate hidden event.
        Start-Sleep -Milliseconds 250
    }
    Write-Output "Closing Baha Plus PID=$($app.Id) scenario=$scenario."
    if (-not [BahaDesktopExitTestNative]::PostMessage($window, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)) {
        throw 'Sending WM_CLOSE to the Baha Plus window failed.'
    }
    # A repeated close request must share the pending teardown, including while minimized.
    [BahaDesktopExitTestNative]::PostMessage($window, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    if (-not $app.WaitForExit(30000)) {
        throw "Baha Plus did not exit within 30 seconds for '$scenario'. PID=$($app.Id); inspect the running process."
    }
    $app.WaitForExit()
    $output = Get-Content -LiteralPath $stdout -Raw
    $result = [ordered]@{
        scenario = $scenario
        processId = $app.Id
        startedAt = $started.ToUniversalTime().ToString('o')
        exitedAt = (Get-Date).ToUniversalTime().ToString('o')
        exitCode = $app.ExitCode
        widgetsUnmounted = $output.Contains('[BAHA_DESKTOP] widgets-unmounted')
        nativeDisposed = $output.Contains('[BAHA_DESKTOP] native-disposed')
        nativeCloseAcknowledged = $output.Contains('[BAHA_DESKTOP] exit-allowed')
        webViewReleased = $output -match '(?m): dealloc InAppWebView\r?$'
        hiddenExit = $output.Contains('[BAHA_DESKTOP] exit-requested lifecycle=hidden')
        stdout = $stdout
        stderr = $stderr
    }
    $results += $result
    [ordered]@{
        executableSha256 = $buildInfo.executableSha256
        dartKernelSha256 = $buildInfo.dartKernelSha256
        webViewPluginSha256 = $buildInfo.webViewPluginSha256
        scenarios = $results
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $debugRoot 'exit-test-results.json') -Encoding utf8
    Write-Output ($result | ConvertTo-Json -Compress)
    if ($app.ExitCode -ne 0 -or -not $result.widgetsUnmounted -or -not $result.nativeDisposed -or -not $result.nativeCloseAcknowledged) {
        throw "Baha Plus exit verification failed for '$scenario'."
    }
    if (-not $result.webViewReleased -or ($scenario -eq 'minimized' -and -not $result.hiddenExit)) {
        throw "Baha Plus did not exercise the expected native WebView and lifecycle teardown for '$scenario'."
    }
}
Write-Output 'Both ordinary-entry window exit scenarios passed.'
