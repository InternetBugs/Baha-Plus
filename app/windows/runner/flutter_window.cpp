#include "flutter_window.h"

#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

#include <iostream>
#include <optional>
#include <variant>

#include "flutter/generated_plugin_registrant.h"

namespace {
constexpr UINT kExitTimeoutMilliseconds = 15000;
constexpr UINT_PTR kExitTimerBase = 0x42410000;
}  // namespace

struct FlutterWindow::ExitState {
  HWND window = nullptr;
  bool pending = false;
  bool allow_close = false;
  uint64_t request_id = 0;
  UINT_PTR timer_id = 0;
};

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  lifecycle_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "baha_plus/desktop_lifecycle",
          &flutter::StandardMethodCodec::GetInstance());
  exit_state_ = std::make_shared<ExitState>();
  exit_state_->window = GetHandle();

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (exit_state_) {
    if (exit_state_->timer_id != 0) {
      KillTimer(exit_state_->window, exit_state_->timer_id);
    }
    // Expire reply callbacks before shutting down their messenger.
    exit_state_.reset();
  }
  lifecycle_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::RequestExit(HWND window) {
  const auto state = exit_state_;
  if (!state || !lifecycle_channel_) {
    std::cerr << "[BAHA_DESKTOP_EXIT] rejected reason=channel-unavailable"
              << std::endl;
    return;
  }
  if (state->pending) {
    std::cerr << "[BAHA_DESKTOP_EXIT] pending request=" << state->request_id
              << std::endl;
    return;
  }

  state->pending = true;
  const auto request_id = ++state->request_id;
  // A distinct timer per attempt prevents a queued old WM_TIMER from expiring
  // a later retry. The window and its engine stay alive while Dart cleans up.
  state->timer_id =
      SetTimer(window, kExitTimerBase + static_cast<UINT_PTR>(request_id),
               kExitTimeoutMilliseconds, nullptr);
  const std::weak_ptr<ExitState> weak_state(state);
  if (state->timer_id == 0) {
    CompleteExitRequest(weak_state, request_id, false, "timer-unavailable");
    return;
  }
  std::cerr << "[BAHA_DESKTOP_EXIT] prepareExit request=" << request_id
            << " timeoutMs=" << kExitTimeoutMilliseconds << std::endl;
  lifecycle_channel_->InvokeMethod(
      "prepareExit", nullptr,
      std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
          [weak_state, request_id](const flutter::EncodableValue* result) {
            // Dart's Future<void> completes with a successful null envelope.
            if (!result || result->IsNull()) {
              CompleteExitRequest(weak_state, request_id, true, "ready-null");
              return;
            }
            const auto* ready = std::get_if<bool>(result);
            CompleteExitRequest(
                weak_state, request_id, ready && *ready,
                ready ? (*ready ? "ready" : "dart-refused") : "invalid-reply");
          },
          [weak_state, request_id](const std::string& code, const std::string&,
                                   const flutter::EncodableValue*) {
            CompleteExitRequest(weak_state, request_id, false,
                                "dart-error:" + code);
          },
          [weak_state, request_id]() {
            CompleteExitRequest(weak_state, request_id, false,
                                "not-implemented");
          }));
}

void FlutterWindow::CompleteExitRequest(std::weak_ptr<ExitState> weak_state,
                                        uint64_t request_id,
                                        bool ready,
                                        const std::string& outcome) {
  const auto state = weak_state.lock();
  if (!state || !state->pending || state->request_id != request_id) {
    std::cerr << "[BAHA_DESKTOP_EXIT] ignored stale-reply request=" << request_id
              << std::endl;
    return;
  }
  if (state->timer_id != 0) {
    KillTimer(state->window, state->timer_id);
    state->timer_id = 0;
  }
  state->pending = false;
  std::cerr << "[BAHA_DESKTOP_EXIT] reply request=" << request_id
            << " outcome=" << outcome << std::endl;
  if (ready && IsWindow(state->window)) {
    state->allow_close = true;
    if (!PostMessage(state->window, WM_CLOSE, 0, 0)) {
      state->allow_close = false;
      std::cerr << "[BAHA_DESKTOP_EXIT] rejected reason=post-close-failed"
                << std::endl;
    }
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // WebView2 can add hidden top-level windows, so the engine's last-window
  // heuristic may skip Dart's exit listener. Own the main-window close handshake.
  if (message == WM_CLOSE) {
    std::cerr << "[BAHA_DESKTOP_EXIT] WM_CLOSE window=" << hwnd << std::endl;
    if (exit_state_ && exit_state_->allow_close) {
      exit_state_->allow_close = false;
      std::cerr << "[BAHA_DESKTOP_EXIT] allow-close request="
                << exit_state_->request_id << std::endl;
      std::cout << "[BAHA_DESKTOP] exit-allowed" << std::endl;
      // Bypass the engine's quit heuristic exactly once after Dart's ACK.
      return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
    }
    RequestExit(hwnd);
    return 0;
  }
  if (message == WM_TIMER && exit_state_ &&
      exit_state_->timer_id != 0 && wparam == exit_state_->timer_id) {
    CompleteExitRequest(exit_state_, exit_state_->request_id, false, "timeout");
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
