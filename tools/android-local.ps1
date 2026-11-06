param(
    [ValidateSet('Check', 'Build', 'Run')]
    [string]$Action = 'Build',
    [ValidateSet('debug', 'release')]
    [string]$Mode = 'debug',
    [string]$FlutterSdk = $env:FLUTTER_ROOT,
    [string]$AndroidSdk = $env:ANDROID_HOME,
    [string]$ProxyUrl,
    [string]$Device = 'emulator-5554',
    [string]$TargetPlatform = 'android-x64'
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $FlutterSdk -and (Test-Path 'D:\BahaPlusTools\flutter\bin\flutter.bat')) {
    $FlutterSdk = 'D:\BahaPlusTools\flutter'
}
if (-not $FlutterSdk) {
    $flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
    if ($flutterCommand) { $FlutterSdk = Split-Path -Parent (Split-Path -Parent $flutterCommand.Source) }
}
if (-not $FlutterSdk) { throw 'Set FLUTTER_ROOT or pass -FlutterSdk.' }
if (-not $AndroidSdk) { $AndroidSdk = Join-Path $projectRoot '.tools\android-sdk' }
$flutterTool = Join-Path $FlutterSdk 'bin\flutter.bat'
if (-not (Test-Path -LiteralPath $flutterTool)) { throw "Flutter not found: $flutterTool" }
$env:FLUTTER_ROOT = $FlutterSdk
$env:ANDROID_HOME = $AndroidSdk
$env:ANDROID_SDK_ROOT = $AndroidSdk
$toolStorage = Split-Path -Parent $FlutterSdk
if (-not $env:PUB_CACHE) { $env:PUB_CACHE = Join-Path $toolStorage 'pub-cache' }
if (-not $env:GRADLE_USER_HOME) { $env:GRADLE_USER_HOME = Join-Path $toolStorage 'gradle' }
if (-not $env:JAVA_HOME -and (Test-Path 'D:\Zulu 21\bin\java.exe')) { $env:JAVA_HOME = 'D:\Zulu 21' }
if ($ProxyUrl) {
    $proxy = [Uri]$ProxyUrl
    if ($proxy.Scheme -ne 'http' -or $proxy.UserInfo) { throw 'Use a local HTTP proxy URL without credentials.' }
    $env:GRADLE_OPTS = "-Dhttp.proxyHost=$($proxy.Host) -Dhttp.proxyPort=$($proxy.Port) -Dhttps.proxyHost=$($proxy.Host) -Dhttps.proxyPort=$($proxy.Port) -Dhttp.nonProxyHosts=127.* -Dorg.gradle.internal.http.connectionTimeout=30000 -Dorg.gradle.internal.http.socketTimeout=120000"
}
Push-Location (Join-Path $projectRoot 'app')
try {
    & $flutterTool pub get
    if ($LASTEXITCODE -ne 0) { throw 'Flutter dependency resolution failed.' }
    if ($Action -eq 'Check') {
        & $flutterTool analyze --no-pub
        if ($LASTEXITCODE -ne 0) { throw 'Flutter analysis failed.' }
        & $flutterTool test --no-pub
        if ($LASTEXITCODE -ne 0) { throw 'Flutter tests failed.' }
    } elseif ($Action -eq 'Run') {
        & $flutterTool run -d $Device "--$Mode" --no-pub
        if ($LASTEXITCODE -ne 0) { throw 'Flutter run failed.' }
    } else {
        & $flutterTool build apk "--$Mode" --target-platform $TargetPlatform --no-pub
        if ($LASTEXITCODE -ne 0) { throw 'Flutter Android build failed.' }
        $output = Join-Path $projectRoot 'artifacts\flutter-local'
        New-Item -ItemType Directory -Path $output -Force | Out-Null
        $apk = Join-Path $output "BahaPlus-$Mode.apk"
        Copy-Item -LiteralPath "build\app\outputs\flutter-apk\app-$Mode.apk" -Destination $apk -Force
        [pscustomobject]@{
            APK = $apk
            SHA256 = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant()
            Mode = $Mode
            TargetPlatform = $TargetPlatform
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output "build-$Mode.json") -Encoding utf8
        Write-Output "Local APK: $apk"
    }
} finally {
    Pop-Location
}
