param(
    [Parameter(Mandatory = $true)]
    [string]$DesktopProject
)

$ErrorActionPreference = 'Stop'
$configurationPath = Join-Path $DesktopProject '.dart_tool\package_config.json'
$configurationSha256 = (Get-FileHash -LiteralPath $configurationPath -Algorithm SHA256).Hash
$configuration = Get-Content -LiteralPath $configurationPath -Raw | ConvertFrom-Json
$package = @($configuration.packages | Where-Object name -eq 'flutter_inappwebview_windows')
if ($package.Count -ne 1) { throw 'Resolve the unmodified desktop dependencies before preparing the Windows WebView patch.' }
$configurationUri = [Uri]::new((Resolve-Path -LiteralPath $configurationPath).Path)
$sourceUri = [Uri]::new($configurationUri, [string]$package[0].rootUri)
if (-not $sourceUri.IsFile) { throw 'The resolved Windows WebView package must be a local directory.' }
$sourcePackage = $sourceUri.LocalPath
$relativeManager = 'windows\in_app_webview\in_app_webview_manager.cpp'
$originalManager = Join-Path $sourcePackage $relativeManager
$upstreamSha256 = 'EEFC7B984C208696B3A3A34F99B0DDC11779FB7470009EBBABCFD274421D77AB'
$upstreamHeaderSha256 = '0470BEBE55ABAA760FD804E01AB7E8D99BEBE5AA3757B368929C68CD0081C0B7'
$reviewedSources = [ordered]@{
    'windows\in_app_webview\in_app_webview.cpp' = '4CB00551207FC4F3B5F9642C2C6A79C50F89C86B2C859129C99C12D524DDEB18'
    'windows\custom_platform_view\custom_platform_view.cc' = 'B54FD686FB213CF2BD0817DFB27FBAF36C451C00F149D5E55A17A16C6ADCF086'
}
if ((Get-FileHash -LiteralPath $originalManager -Algorithm SHA256).Hash -ne $upstreamSha256) {
    throw 'The Windows WebView source differs from the reviewed 0.6.0 package. Review the desktop shutdown patch before building.'
}
if ((Get-FileHash -LiteralPath (Join-Path $sourcePackage 'windows\in_app_webview\in_app_webview_manager.h') -Algorithm SHA256).Hash -ne $upstreamHeaderSha256) {
    throw 'The Windows WebView manager header differs from the reviewed 0.6.0 package.'
}
if ((Get-Content -LiteralPath (Join-Path $sourcePackage 'pubspec.yaml') -Raw) -notmatch '(?m)^version: 0\.6\.0\s*$') {
    throw 'The Windows WebView shutdown patch only supports package version 0.6.0.'
}
foreach ($reviewedSource in $reviewedSources.GetEnumerator()) {
    if ((Get-FileHash -LiteralPath (Join-Path $sourcePackage $reviewedSource.Key) -Algorithm SHA256).Hash -ne $reviewedSource.Value) {
        throw "The Windows WebView source differs from the reviewed 0.6.0 package: $($reviewedSource.Key)"
    }
}

# Patch a derived copy only. Never change the shared package cache or mobile
# dependencies. The source checksum makes an upstream change an explicit review.
$pluginParent = Join-Path (Split-Path -Parent $DesktopProject) 'plugins'
New-Item -ItemType Directory -Path $pluginParent -Force | Out-Null
$patchedPackage = Join-Path $pluginParent 'flutter_inappwebview_windows'
New-Item -ItemType Directory -Path $patchedPackage -Force | Out-Null
foreach ($entry in Get-ChildItem -LiteralPath $sourcePackage -Force) {
    Copy-Item -LiteralPath $entry.FullName -Destination $patchedPackage -Recurse -Force
}
$managerPath = Join-Path $patchedPackage $relativeManager
$manager = [System.IO.File]::ReadAllText($managerPath)
function Replace-ReviewedAnchor {
    param([string]$Source, [string]$Anchor, [string]$Replacement)
    if ($Source.IndexOf($Anchor) -lt 0 -or $Source.IndexOf($Anchor) -ne $Source.LastIndexOf($Anchor)) {
        throw "The Windows WebView shutdown patch anchor must occur exactly once: $Anchor"
    }
    return $Source.Replace($Anchor, $Replacement)
}
$manager = $manager.Replace("`r`n", "`n")
$manager = Replace-ReviewedAnchor $manager '#include <DispatcherQueue.h>' @'
#include <DispatcherQueue.h>
#include <asyncinfo.h>
#include <atomic>
#include <exception>
#include <sstream>
#include <windows.foundation.h>
'@
$manager = Replace-ReviewedAnchor $manager '#include "../in_app_webview/in_app_webview_settings.h"' @'
#include "../in_app_webview/in_app_webview_settings.h"
#include "../headless_in_app_webview/headless_in_app_webview_manager.h"
#include "../in_app_browser/in_app_browser_manager.h"
#include "../custom_platform_view/webview_desktop_retirement.h"
'@
$manager = Replace-ReviewedAnchor $manager "namespace flutter_inappwebview_plugin`n{" @'
namespace flutter_inappwebview_plugin
{
#include "webview_desktop_exit.inc"
'@
$manager = Replace-ReviewedAnchor $manager '    if (!rohelper_) {' @'
    desktop_exit_states.emplace(this, std::make_shared<DesktopExitState>());
    if (!rohelper_) {
'@
$manager = Replace-ReviewedAnchor $manager '    auto* arguments = std::get_if<flutter::EncodableMap>(method_call.arguments());' @'
    const auto state = desktop_exit_states.at(this);
    if (FAILED(CheckDesktopExitThread(*state))) {
      result->Error("desktop-exit-thread", "Expected the owning platform STA");
      return;
    }
    if (string_equals(method_call.method_name(), "shutdownForDesktopExit")) {
      try {
        state->requested = true;
        valid_ = false;
        // Drain on the first poll even while maps/creates remain. COM release
        // may reenter the platform loop, so Pending also counts active release.
        const auto retirement_hr = desktop_texture_retirement.Drain();
        if (FAILED(retirement_hr)) {
          DesktopExitFailed(*state, retirement_hr, "retire-view-textures");
        }
        if (FAILED(state->failure)) {
          result->Error("desktop-exit", DesktopExitError(*state));
          return;
        }
        if (desktop_exit_states.size() != 1) {
          result->Error("desktop-exit", "Multiple WebView managers are active");
          return;
        }
        // These maps include keep-alive and new-window deferrals. Never clear
        // them to manufacture readiness: the caller must unmount/dispose them.
        if (!webViews.empty() || !keepAliveWebViews.empty() ||
            !windowWebViews.empty() || state->pending_creates != 0 ||
            desktop_texture_retirement.Pending() != 0 ||
            (plugin->inAppBrowserManager &&
             !plugin->inAppBrowserManager->browsers.empty()) ||
            (plugin->headlessInAppWebViewManager &&
             !plugin->headlessInAppWebViewManager->webViews.empty())) {
          result->Success(flutter::EncodableValue(false));
          return;
        }
        bool ready = false;
        const auto hr = PollDesktopExit(
            *state, plugin->registrar->texture_registrar(), compositor_,
            graphics_context_, dispatcher_queue_controller_, rohelper_, &ready);
        if (FAILED(hr)) {
          result->Error("desktop-exit", DesktopExitError(*state));
        } else {
          result->Success(flutter::EncodableValue(ready));
        }
      } catch (const winrt::hresult_error& error) {
        DesktopExitFailed(*state, error.code(), "shutdown-exception");
        result->Error("desktop-exit", DesktopExitError(*state));
      } catch (const std::exception&) {
        DesktopExitFailed(*state, E_FAIL, "shutdown-exception");
        result->Error("desktop-exit", DesktopExitError(*state));
      } catch (...) {
        DesktopExitFailed(*state, E_UNEXPECTED, "shutdown-exception");
        result->Error("desktop-exit", DesktopExitError(*state));
      }
      return;
    }
    if (state->requested &&
        string_equals(method_call.method_name(), "createInAppWebView")) {
      result->Error("desktop-exit", "WebView creation is disabled during exit");
      return;
    }
    auto* arguments = std::get_if<flutter::EncodableMap>(method_call.arguments());
'@
$manager = Replace-ReviewedAnchor $manager '    if (!plugin) {' @'
    const auto state = desktop_exit_states.at(this);
    if (state->requested || !state->alive) {
      result_->Error("desktop-exit", "WebView creation is disabled during exit");
      return;
    }
    if (!plugin) {
'@
$manager = Replace-ReviewedAnchor $manager '      auto webView = std::move(keepAliveWebViews.at(keepAliveId.value())->view);' @'
      // The old platform view loses its view before its destructor runs.
      // Remove callbacks that capture the old `this` before that move.
      keepAliveWebViews.at(keepAliveId.value())->view->onSurfaceSizeChanged(nullptr);
      keepAliveWebViews.at(keepAliveId.value())->view->onCursorChanged(nullptr);
      auto webView = std::move(keepAliveWebViews.at(keepAliveId.value())->view);
'@
$manager = Replace-ReviewedAnchor $manager '    InAppWebView::createInAppWebViewEnv(hwnd, true, webViewEnvironment, initialSettings,' @'
    const auto pending = std::make_shared<DesktopPendingCreation>(state);
    try {
    InAppWebView::createInAppWebViewEnv(hwnd, true, webViewEnvironment, initialSettings,
'@
$manager = Replace-ReviewedAnchor $manager '        if (plugin && webViewEnv && webViewController && webViewCompositionController) {' @'
        if (!pending->CompleteOnce()) {
          // The first completion owns (or already destroyed) this HWND.
          return;
        }
        const DesktopCreationCompletion completion{pending};
        // Do not dereference the captured manager after its destruction, or
        // create a new surface once shutdown has begun. No Flutter reply may
        // use the messenger after the manager/engine has gone away.
        if (!state->alive || state->requested) {
          const auto hr = CancelDesktopCreation(
              hwnd, webViewController, webViewCompositionController, webViewEnv);
          if (FAILED(hr)) {
            DesktopExitFailed(*state, hr, "cancel-pending-create");
          }
          if (state->alive) {
            result_->Error("desktop-exit", "Pending WebView creation canceled");
          }
          return;
        }
        if (plugin && webViewEnv && webViewController && webViewCompositionController) {
'@
$manager = Replace-ReviewedAnchor $manager '          result_->Error("0", "Cannot create the InAppWebView instance!");' @'
          const auto hr = CancelDesktopCreation(
              hwnd, webViewController, webViewCompositionController, webViewEnv);
          if (FAILED(hr)) {
            DesktopExitFailed(*state, hr, "release-failed-create");
          }
          result_->Error("0", "Cannot create the InAppWebView instance!");
'@
$manager = Replace-ReviewedAnchor $manager "    );`n  }`n`n  void InAppWebViewManager::disposeKeepAlive" @'
    );
    } catch (...) {
      // A synchronous failure before callback delivery must not strand the
      // pending count or allow the exit poll to report success.
      if (pending->CompleteOnce()) {
        pending->Release();
        if (IsWindow(hwnd)) DestroyWindow(hwnd);
        result_->Error("desktop-create", "WebView creation failed");
      } else {
        DesktopExitFailed(*state, E_FAIL, "create-callback-exception");
      }
    }
  }

  void InAppWebViewManager::disposeKeepAlive
'@
$manager = Replace-ReviewedAnchor $manager '    debugLog("dealloc InAppWebViewManager");' @'
    debugLog("dealloc InAppWebViewManager");
    const auto found = desktop_exit_states.find(this);
    const auto state = found == desktop_exit_states.end() ? nullptr : found->second;
    if (state) state->alive = false;
'@
$manager = Replace-ReviewedAnchor $manager '    windowWebViews.clear();' @'
    windowWebViews.clear();
    // Nonblocking fallback for a host that bypasses the explicit handshake.
    // Successful desktop exit has already emptied all these COM references.
    if (state) {
      if (!state->ready) debugLog("Baha desktop exit: incomplete handshake");
      state->info = nullptr;
      state->action = nullptr;
    }
    if (desktop_exit_states.size() <= 1) {
      compositor_ = nullptr;
      graphics_context_.reset();
      dispatcher_queue_controller_ = nullptr;
      rohelper_.reset();
      valid_ = false;
    }
    desktop_exit_states.erase(this);
'@
[System.IO.File]::WriteAllText($managerPath, $manager, [System.Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'patches\webview_desktop_exit.inc') `
    -Destination (Join-Path (Split-Path -Parent $managerPath) 'webview_desktop_exit.inc') -Force

$creationPath = Join-Path $patchedPackage 'windows\in_app_webview\in_app_webview.cpp'
$creation = [System.IO.File]::ReadAllText($creationPath).Replace("`r`n", "`n")
$creationStart = '  void InAppWebView::createInAppWebViewEnv('
$creationEnd = '  void InAppWebView::initChannel('
foreach ($methodAnchor in @($creationStart, $creationEnd)) {
    if ($creation.IndexOf($methodAnchor) -lt 0 -or $creation.IndexOf($methodAnchor) -ne $creation.LastIndexOf($methodAnchor)) {
        throw "The reviewed WebView creation method anchor must occur exactly once: $methodAnchor"
    }
}
$methodStart = $creation.IndexOf($creationStart)
$methodLength = $creation.IndexOf($creationEnd) - $methodStart
if ($methodLength -le 0) { throw 'The reviewed WebView creation method boundaries have changed.' }
$creation = Replace-ReviewedAnchor $creation $creation.Substring($methodStart, $methodLength) "#include `"webview_desktop_creation.inc`"`n`n"
[System.IO.File]::WriteAllText($creationPath, $creation, [System.Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'patches\webview_desktop_creation.inc') `
    -Destination (Join-Path (Split-Path -Parent $creationPath) 'webview_desktop_creation.inc') -Force

$platformViewPath = Join-Path $patchedPackage 'windows\custom_platform_view\custom_platform_view.cc'
$platformView = [System.IO.File]::ReadAllText($platformViewPath).Replace("`r`n", "`n")
$platformView = Replace-ReviewedAnchor $platformView '#include "custom_platform_view.h"' @'
#include "custom_platform_view.h"
#include "webview_desktop_retirement.h"
'@
$platformView = Replace-ReviewedAnchor $platformView @'
    event_sink_ = nullptr;
    texture_registrar_->UnregisterTexture(texture_id_, nullptr);
'@ @'
    UnregisterMethodCallHandler();
    if (event_channel_) event_channel_->SetStreamHandler(nullptr);
    event_sink_ = nullptr;
    if (view) {
      view->onSurfaceSizeChanged(nullptr);
      view->onCursorChanged(nullptr);
    }
    // Stop synchronizes with capture/raster bridge access. Once stopped, no
    // capture callback can continue to refer to this CustomPlatformView.
    texture_bridge_->Stop();
    texture_bridge_->SetOnFrameAvailable(nullptr);
    texture_bridge_->SetOnSurfaceSizeChanged(nullptr);
    auto resources =
        std::make_unique<DesktopRetiredView<TextureBridge, InAppWebView>>(
            std::move(flutter_texture_), std::move(texture_bridge_),
            std::move(view));
    // The completion holds only an atomic. The STA timer (or shutdown poll)
    // destroys texture, bridge and view after actual raster unregistration.
    failedLog(desktop_texture_retirement.Retire(
        texture_registrar_, texture_id_, std::move(resources)));
'@
[System.IO.File]::WriteAllText($platformViewPath, $platformView, [System.Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'patches\webview_desktop_retirement.h') `
    -Destination (Join-Path (Split-Path -Parent $platformViewPath) 'webview_desktop_retirement.h') -Force

$pubspecPath = Join-Path $DesktopProject 'pubspec.yaml'
$desktopPubspecInputSha256 = (Get-FileHash -LiteralPath $pubspecPath -Algorithm SHA256).Hash
$pubspec = [System.IO.File]::ReadAllText($pubspecPath)
if ($pubspec -match '(?m)^dependency_overrides:') {
    throw 'The generated desktop pubspec already has dependency overrides; review it before applying the Windows-only patch.'
}
$pubspec += @'

dependency_overrides:
  flutter_inappwebview_windows:
    path: ../plugins/flutter_inappwebview_windows

'@
[System.IO.File]::WriteAllText($pubspecPath, $pubspec, [System.Text.UTF8Encoding]::new($false))
$sourceInputs = [ordered]@{
    $relativeManager = $upstreamSha256
    'windows\in_app_webview\in_app_webview_manager.h' = $upstreamHeaderSha256
    'pubspec.yaml' = (Get-FileHash -LiteralPath (Join-Path $sourcePackage 'pubspec.yaml') -Algorithm SHA256).Hash
}
foreach ($reviewedSource in $reviewedSources.GetEnumerator()) {
    $sourceInputs[$reviewedSource.Key] = $reviewedSource.Value
}
$patchInputs = [ordered]@{
    'tools\windows\prepare_webview.ps1' = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
}
foreach ($patchInput in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'patches') -File | Sort-Object Name) {
    $patchInputs['tools\windows\patches\' + $patchInput.Name] = (Get-FileHash -LiteralPath $patchInput.FullName -Algorithm SHA256).Hash
}
$patchedOutputs = [ordered]@{}
foreach ($outputFile in @(
    $relativeManager,
    'windows\in_app_webview\in_app_webview_manager.h',
    'windows\in_app_webview\in_app_webview.cpp',
    'windows\custom_platform_view\custom_platform_view.cc',
    'windows\in_app_webview\webview_desktop_exit.inc',
    'windows\in_app_webview\webview_desktop_creation.inc',
    'windows\custom_platform_view\webview_desktop_retirement.h',
    'pubspec.yaml'
)) {
    $patchedOutputs[$outputFile] = (Get-FileHash -LiteralPath (Join-Path $patchedPackage $outputFile) -Algorithm SHA256).Hash
}
[ordered]@{
    schemaVersion = 2
    hashAlgorithm = 'SHA256'
    package = 'flutter_inappwebview_windows'
    version = '0.6.0'
    sourceInputs = $sourceInputs
    patchInputs = $patchInputs
    patchedOutputs = $patchedOutputs
    desktopProjectInputs = [ordered]@{
        '.dart_tool\package_config.json' = $configurationSha256
        'pubspec.yaml' = $desktopPubspecInputSha256
    }
    desktopProjectOutputs = [ordered]@{
        'pubspec.yaml' = (Get-FileHash -LiteralPath $pubspecPath -Algorithm SHA256).Hash
    }
    upstreamFile = $relativeManager
    upstreamSha256 = $upstreamSha256
    upstreamHeaderSha256 = $upstreamHeaderSha256
    patchedSha256 = (Get-FileHash -LiteralPath $managerPath -Algorithm SHA256).Hash
    helperSha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'patches\webview_desktop_exit.inc') -Algorithm SHA256).Hash
    reviewedSources = $reviewedSources
    patchedSources = [ordered]@{
        'windows\in_app_webview\in_app_webview.cpp' = (Get-FileHash -LiteralPath $creationPath -Algorithm SHA256).Hash
        'windows\custom_platform_view\custom_platform_view.cc' = (Get-FileHash -LiteralPath $platformViewPath -Algorithm SHA256).Hash
    }
    creationHelperSha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'patches\webview_desktop_creation.inc') -Algorithm SHA256).Hash
    retirementHelperSha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'patches\webview_desktop_retirement.h') -Algorithm SHA256).Hash
    method = 'com.pichillilorenzo/flutter_inappwebview_manager.shutdownForDesktopExit'
    reason = 'Drain raster work and asynchronously shut down the owned dispatcher queue on STA before COM shutdown and DLL detach.'
    limits = @(
        'Supports the derived application inline WebView path; sibling browser/headless creation is not intercepted.',
        'Per-view retirement requires the platform message loop or host shutdown polling to remain active.',
        'The host must poll until true and keep its engine and HWND alive; errors must prevent an exit ACK.'
    )
    upstreamIssue = 'https://github.com/pichillilorenzo/flutter_inappwebview/issues/2733'
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $pluginParent 'webview-patch.json') -Encoding utf8
Write-Output 'Prepared the reviewed Windows-only WebView shutdown patch in the derived project.'
