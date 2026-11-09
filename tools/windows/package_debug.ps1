param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$debugRoot = Join-Path $projectRoot 'artifacts\windows-debug'
$buildInfo = Get-Content -LiteralPath (Join-Path $debugRoot 'build-info.json') -Raw | ConvertFrom-Json
$exitTests = Get-Content -LiteralPath (Join-Path $debugRoot 'exit-test-results.json') -Raw | ConvertFrom-Json
$binaryRoot = Join-Path $debugRoot 'source\build\windows\x64\runner\Debug'
$verifiedFiles = [ordered]@{
    'baha_plus.exe' = $buildInfo.executableSha256
    'data\flutter_assets\kernel_blob.bin' = $buildInfo.dartKernelSha256
    'flutter_inappwebview_windows_plugin.dll' = $buildInfo.webViewPluginSha256
}
if ($buildInfo.entrypoint -ne 'lib/desktop_main.dart') {
    throw 'Only the ordinary desktop entrypoint can be packaged.'
}
foreach ($file in $verifiedFiles.GetEnumerator()) {
    if ((Get-FileHash -LiteralPath (Join-Path $binaryRoot $file.Key) -Algorithm SHA256).Hash -ne $file.Value) {
        throw "The current build differs from its build record: $($file.Key)"
    }
}
if ($exitTests.executableSha256 -ne $buildInfo.executableSha256 -or
    $exitTests.dartKernelSha256 -ne $buildInfo.dartKernelSha256 -or
    $exitTests.webViewPluginSha256 -ne $buildInfo.webViewPluginSha256) {
    throw 'Run window exit tests against this ordinary desktop build before packaging it.'
}
foreach ($scenario in @('normal', 'minimized')) {
    $passed = @($exitTests.scenarios | Where-Object {
        $_.scenario -eq $scenario -and $_.exitCode -eq 0 -and
        $_.widgetsUnmounted -and $_.nativeDisposed -and
        $_.nativeCloseAcknowledged -and $_.webViewReleased -and
        ($scenario -ne 'minimized' -or $_.hiddenExit)
    })
    if ($passed.Count -ne 1) { throw "Window exit scenario '$scenario' has not passed." }
}

# Use CMake's install manifest and explicit debug symbols. Runtime-generated
# WebView2 profiles live beside the EXE and must never enter a distributable.
$inputs = @{}
$prefix = [System.IO.Path]::GetFullPath($binaryRoot).TrimEnd('\') + '\'
$manifest = Join-Path $debugRoot 'source\build\windows\x64\install_manifest.txt'
$runtimePaths = @((Get-Content -LiteralPath $manifest) | Where-Object { $_.Trim() })
$runtimePaths += @('baha_plus.exe', 'baha_plus.pdb', 'WebView2Loader.dll', 'flutter_inappwebview_windows_plugin.pdb') | ForEach-Object {
    Join-Path $binaryRoot $_
}
foreach ($file in $runtimePaths) {
    $absolute = [System.IO.Path]::GetFullPath($file)
    if (-not $absolute.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The install manifest references a file outside the expected Debug directory: $absolute"
    }
    $relative = $absolute.Substring($prefix.Length).Replace('\', '/')
    if ($relative -match '(?i)(^|/)[^/]*\.WebView2(/|$)') {
        throw 'A runtime WebView2 profile is not a package input.'
    }
    if (-not (Test-Path -LiteralPath $absolute -PathType Leaf)) {
        throw "A package input is missing: $absolute"
    }
    $inputs[$relative] = $absolute
}
$inputs['build-info.json'] = Join-Path $debugRoot 'build-info.json'
$inputs['exit-test-results.json'] = Join-Path $debugRoot 'exit-test-results.json'
$hashes = @{}
foreach ($name in $inputs.Keys) {
    $hashes[$name] = (Get-FileHash -LiteralPath $inputs[$name] -Algorithm SHA256).Hash
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$temporaryArchive = Join-Path $debugRoot 'BahaPlus-windows-debug.building.zip'
$archivePath = Join-Path $debugRoot 'BahaPlus-windows-debug.zip'
$stream = [System.IO.File]::Open($temporaryArchive, [System.IO.FileMode]::Create)
try {
    $archive = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        foreach ($name in ($inputs.Keys | Sort-Object)) {
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $archive, $inputs[$name], $name, [System.IO.Compression.CompressionLevel]::Optimal
            ) | Out-Null
        }
        $entry = $archive.CreateEntry('PACKAGE_FILES_SHA256.txt')
        $writer = [System.IO.StreamWriter]::new($entry.Open(), [System.Text.UTF8Encoding]::new($false))
        try {
            foreach ($name in ($hashes.Keys | Sort-Object)) {
                $writer.WriteLine("$($hashes[$name])  $name")
            }
        } finally { $writer.Dispose() }
    } finally { $archive.Dispose() }
} finally { $stream.Dispose() }

# Verify bytes after ZIP creation as well as the package allowlist.
$archive = [System.IO.Compression.ZipFile]::OpenRead($temporaryArchive)
$sha256 = [System.Security.Cryptography.SHA256]::Create()
try {
    if ($archive.Entries.Count -ne $inputs.Count + 1) { throw 'Unexpected archive entry count.' }
    foreach ($entry in $archive.Entries) {
        if ($entry.FullName -eq 'PACKAGE_FILES_SHA256.txt') { continue }
        if (-not $inputs.ContainsKey($entry.FullName)) { throw "Unexpected archive input: $($entry.FullName)" }
        $entryStream = $entry.Open()
        try { $actual = [BitConverter]::ToString($sha256.ComputeHash($entryStream)).Replace('-', '') }
        finally { $entryStream.Dispose() }
        if ($actual -ne $hashes[$entry.FullName]) { throw "ZIP verification failed: $($entry.FullName)" }
    }
} finally {
    $sha256.Dispose()
    $archive.Dispose()
}
Move-Item -LiteralPath $temporaryArchive -Destination $archivePath -Force
$archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
"$archiveHash  BahaPlus-windows-debug.zip" | Set-Content -LiteralPath (Join-Path $debugRoot 'SHA256SUMS.txt') -Encoding ascii
Write-Output "Verified desktop Debug package: $archivePath"
Write-Output "Files=$($inputs.Count + 1) bytes=$((Get-Item -LiteralPath $archivePath).Length) SHA256=$archiveHash"
