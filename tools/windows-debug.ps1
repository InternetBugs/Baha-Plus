param(
    [ValidateSet('Prepare', 'Build', 'Run', 'Test')]
    [string]$Action = 'Build',
    [string]$FlutterSdk = 'D:\BahaPlusTools\flutter'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$debugRoot = Join-Path $projectRoot 'artifacts\windows-debug'
$debugSource = Join-Path $debugRoot 'source'
$flutterTool = Join-Path $FlutterSdk 'bin\flutter.bat'
if (-not (Test-Path -LiteralPath $flutterTool)) {
    throw "Flutter SDK not found: $flutterTool"
}
if (-not $env:PUB_CACHE) {
    $env:PUB_CACHE = Join-Path (Split-Path -Parent $FlutterSdk) 'pub-cache'
}
$env:FLUTTER_ROOT = $FlutterSdk
$nugetDirectory = Join-Path $debugRoot 'toolchain'
if (Test-Path -LiteralPath (Join-Path $nugetDirectory 'nuget.exe')) {
    $env:PATH = "$nugetDirectory;$env:PATH"
}

function Invoke-Flutter {
    param([string[]]$FlutterArguments)
    & $flutterTool @FlutterArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter failed with exit code $LASTEXITCODE."
    }
}

function Copy-WindowsSources {
    param([string]$Origin, [string]$Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($entry in Get-ChildItem -LiteralPath $Origin -Force) {
        # Flutter owns ephemeral files and plugin symlinks in the derived
        # project. Following them can copy the shared pub cache onto itself.
        if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $entry.Name -eq 'ephemeral' -or
            $entry.Name -in @('generated_plugin_registrant.cc', 'generated_plugin_registrant.h', 'generated_plugins.cmake')) {
            continue
        }
        $target = Join-Path $Destination $entry.Name
        if ($entry.PSIsContainer) {
            Copy-WindowsSources -Origin $entry.FullName -Destination $target
        } else {
            Copy-Item -LiteralPath $entry.FullName -Destination $target -Force
        }
    }
}

New-Item -ItemType Directory -Path $debugSource -Force | Out-Null
foreach ($directory in @('lib', 'assets', 'windows')) {
    $origin = Join-Path $projectRoot "app\$directory"
    if (-not (Test-Path -LiteralPath $origin)) {
        throw "Missing desktop build input: $origin"
    }
    if ($directory -eq 'windows') {
        Copy-WindowsSources -Origin $origin -Destination (Join-Path $debugSource $directory)
    } else {
        Copy-Item -LiteralPath $origin -Destination $debugSource -Recurse -Force
    }
}
foreach ($filename in @('pubspec.lock', 'analysis_options.yaml')) {
    Copy-Item -LiteralPath (Join-Path $projectRoot "app\$filename") -Destination $debugSource -Force
}

# Keep desktop native dependencies out of the mobile application's lockfile.
# The generated project builds the current app source and the same assets.
$pubspec = Get-Content -LiteralPath (Join-Path $projectRoot 'app\pubspec.yaml') -Raw
$videoLine = [regex]::Match($pubspec, '(?m)^  video_player:[^\r\n]*').Value
if (-not $videoLine) { throw 'The mobile video_player dependency was not found.' }
$pubspec = $pubspec.Replace($videoLine, @"
$videoLine
  video_player_media_kit: 2.0.0
  media_kit_libs_windows_video: 1.0.11
"@)
Set-Content -LiteralPath (Join-Path $debugSource 'pubspec.yaml') -Value $pubspec -Encoding utf8
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'windows\desktop_main.dart') `
    -Destination (Join-Path $debugSource 'lib\desktop_main.dart') -Force
$integrationDirectory = Join-Path $debugSource 'integration_test'
New-Item -ItemType Directory -Path $integrationDirectory -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'windows\desktop_smoke_test.dart') `
    -Destination (Join-Path $integrationDirectory 'desktop_smoke_test.dart') -Force

if ($Action -eq 'Test') {
    $fixtureDirectory = Join-Path $debugRoot 'fixtures'
    $fixtureFiles = @('index.m3u8', 'init.mp4', 'segment-00.m4s', 'segment-01.m4s', 'segment-02.m4s', 'segment-03.m4s')
    $missingFixture = @($fixtureFiles | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $fixtureDirectory $_))
    })
    if ($missingFixture.Count -gt 0) {
        $ffmpegTool = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
        if (-not $ffmpegTool) {
            throw "The local HLS smoke fixture is missing. Add FFmpeg to PATH to generate it in $fixtureDirectory."
        }
        New-Item -ItemType Directory -Path $fixtureDirectory -Force | Out-Null
        Push-Location -LiteralPath $fixtureDirectory
        try {
            & $ffmpegTool.Source -hide_banner -loglevel error -nostdin -y `
                -f lavfi -i 'testsrc2=size=256x144:rate=10' `
                -t 8 -an -c:v libx264 -threads 1 -preset veryfast -crf 28 `
                -pix_fmt yuv420p -g 20 -keyint_min 20 -sc_threshold 0 `
                -f hls -hls_time 2 -hls_list_size 0 `
                -hls_segment_type fmp4 -hls_flags independent_segments `
                -hls_fmp4_init_filename init.mp4 `
                -hls_segment_filename 'segment-%02d.m4s' index.m3u8
            if ($LASTEXITCODE -ne 0) { throw 'Generating the local HLS fixture failed.' }
        }
        finally {
            Pop-Location
        }
    }
    $env:BAHA_DESKTOP_FIXTURE = (Resolve-Path -LiteralPath $fixtureDirectory).Path
}

Push-Location -LiteralPath $debugSource
try {
    Invoke-Flutter -FlutterArguments @('pub', 'get')
    & (Join-Path $PSScriptRoot 'windows\prepare_webview.ps1') -DesktopProject $debugSource
    Invoke-Flutter -FlutterArguments @('pub', 'get')
    $defines = @('--dart-define=BAHA_WINDOWS_NATIVE=true', '--dart-define=BAHA_DIAGNOSTICS=true')
    switch ($Action) {
        'Build' {
            Invoke-Flutter -FlutterArguments (@('build', 'windows', '--debug', '--target', 'lib/desktop_main.dart') + $defines)
            $binary = Join-Path $debugSource 'build\windows\x64\runner\Debug\baha_plus.exe'
            if (-not (Test-Path -LiteralPath $binary)) { throw "Missing executable: $binary" }
            $webViewSymbols = Join-Path $debugSource 'build\windows\x64\plugins\flutter_inappwebview_windows\Debug\flutter_inappwebview_windows_plugin.pdb'
            Copy-Item -LiteralPath $webViewSymbols -Destination (Split-Path -Parent $binary) -Force
            [ordered]@{
                executable = $binary
                buildMode = 'debug'
                nativeBackend = 'windows-mpv'
                entrypoint = 'lib/desktop_main.dart'
                sourceBranch = & 'C:\Program Files\Git\cmd\git.exe' -C $projectRoot branch --show-current
                sourceCommit = & 'C:\Program Files\Git\cmd\git.exe' -C $projectRoot rev-parse HEAD
                includesUncommittedChanges = $true
                executableSha256 = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash
                dartKernelSha256 = (Get-FileHash -LiteralPath (Join-Path (Split-Path -Parent $binary) 'data\flutter_assets\kernel_blob.bin') -Algorithm SHA256).Hash
                webViewPluginSha256 = (Get-FileHash -LiteralPath (Join-Path (Split-Path -Parent $binary) 'flutter_inappwebview_windows_plugin.dll') -Algorithm SHA256).Hash
                desktopWebViewPatch = Get-Content -LiteralPath (Join-Path $debugRoot 'plugins\webview-patch.json') -Raw | ConvertFrom-Json
                builtAt = (Get-Date).ToUniversalTime().ToString('o')
            } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $debugRoot 'build-info.json') -Encoding utf8
            Write-Output "Desktop Debug executable: $binary"
        }
        'Run' {
            Invoke-Flutter -FlutterArguments (@('run', '-d', 'windows', '--debug', '--target', 'lib/desktop_main.dart') + $defines)
        }
        'Test' {
            Invoke-Flutter -FlutterArguments (@('test', '-d', 'windows', 'integration_test/desktop_smoke_test.dart') + $defines)
        }
    }
}
finally {
    Pop-Location
}
