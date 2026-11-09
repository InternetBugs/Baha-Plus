// Baha Plus desktop-only shutdown support for flutter_inappwebview_windows 0.6.0.
// Included inside flutter_inappwebview_plugin by the reviewed manager.cpp patch.
// All COM ownership stays on the manager's platform/STA thread. Per-view
// retirement and the final sentinel both finish before graphics are released.
namespace {
struct DesktopExitState {
  DWORD thread = GetCurrentThreadId();
  bool alive = true;
  bool requested = false;
  bool graphics_released = false;
  bool ready = false;
  size_t pending_creates = 0;
  HRESULT failure = S_OK;
  const char* failure_stage = "";
  std::shared_ptr<std::atomic<int>> raster_fence;
  winrt::com_ptr<ABI::Windows::Foundation::IAsyncAction> action;
  winrt::com_ptr<::IAsyncInfo> info;
};

// Erased by the manager destructor on its owning thread. No COM reference is
// intentionally left for this container's process/DLL static destruction.
std::map<InAppWebViewManager*, std::shared_ptr<DesktopExitState>>
    desktop_exit_states;

HRESULT DesktopExitFailed(DesktopExitState& state, HRESULT error,
                          const char* stage) {
  state.failure = FAILED(error) ? error : E_FAIL;
  state.failure_stage = stage;
  return state.failure;
}

std::string DesktopExitError(const DesktopExitState& state) {
  std::ostringstream message;
  message << state.failure_stage << " HRESULT=0x" << std::hex
          << static_cast<unsigned long>(state.failure);
  return message.str();
}

HRESULT CheckDesktopExitThread(DesktopExitState& state) {
  if (GetCurrentThreadId() != state.thread) {
    return RPC_E_WRONG_THREAD;
  }
  APTTYPE apartment;
  APTTYPEQUALIFIER qualifier;
  const auto hr = CoGetApartmentType(&apartment, &qualifier);
  if (FAILED(hr)) return hr;
  return apartment == APTTYPE_STA || apartment == APTTYPE_MAINSTA
             ? S_OK
             : RPC_E_WRONG_THREAD;
}

HRESULT PollDesktopExit(
    DesktopExitState& state, flutter::TextureRegistrar* registrar,
    winrt::com_ptr<ABI::Windows::UI::Composition::ICompositor>& compositor,
    std::unique_ptr<GraphicsContext>& graphics,
    winrt::com_ptr<ABI::Windows::System::IDispatcherQueueController>& controller,
    std::shared_ptr<rx::RoHelper>& rohelper, bool* ready) {
  *ready = false;
  const auto retirement_hr = desktop_texture_retirement.Drain();
  if (FAILED(retirement_hr)) {
    return DesktopExitFailed(state, retirement_hr, "retire-view-textures");
  }
  if (FAILED(state.failure)) return state.failure;
  if (desktop_texture_retirement.Pending() != 0) return S_OK;
  if (state.ready) {
    *ready = true;
    return S_OK;
  }

  if (!state.raster_fence) {
    // The pinned Windows engine processes texture unregister work on its
    // raster task runner. Enqueue this only after all managed views and all
    // their creation callbacks and per-view texture retirements have finished.
    const auto signal = std::make_shared<std::atomic<int>>(0);
    const auto texture = std::make_shared<flutter::TextureVariant>(
        flutter::PixelBufferTexture(
            [](size_t, size_t) -> const FlutterDesktopPixelBuffer* {
              return nullptr;
            }));
    const auto id = registrar->RegisterTexture(texture.get());
    if (id < 0) {
      return DesktopExitFailed(state, E_FAIL, "register-raster-fence");
    }
    state.raster_fence = signal;
    const auto platform_thread = state.thread;
    registrar->UnregisterTexture(id, [signal, texture, platform_thread]() {
      // The pinned engine also invokes this callback synchronously if posting
      // its raster task fails. Reject that path instead of treating it as a
      // successful drain. No STA object is released by this callback.
      signal->store(GetCurrentThreadId() == platform_thread ? -1 : 1,
                    std::memory_order_release);
    });
    return S_OK;
  }

  const auto fence = state.raster_fence->load(std::memory_order_acquire);
  if (fence == 0) return S_OK;
  if (fence < 0) {
    return DesktopExitFailed(state, E_FAIL, "post-raster-fence");
  }

  if (!state.graphics_released) {
    state.graphics_released = true;
    compositor = nullptr;
    graphics.reset();
    debugLog("Baha desktop exit: graphics released on STA");

    if (controller) {
      auto hr = controller->ShutdownQueueAsync(state.action.put());
      if (FAILED(hr) || !state.action) {
        return DesktopExitFailed(state, FAILED(hr) ? hr : E_POINTER,
                                 "start-queue-shutdown");
      }
      hr = state.action->QueryInterface(__uuidof(::IAsyncInfo),
                                       state.info.put_void());
      if (FAILED(hr) || !state.info) {
        return DesktopExitFailed(state, FAILED(hr) ? hr : E_NOINTERFACE,
                                 "query-async-info");
      }
      debugLog("Baha desktop exit: queue shutdown started");
    }
  }

  if (state.action) {
    // ABI IAsyncAction does not inherit IAsyncInfo. Query it explicitly; do not
    // use Completed or touch COM objects from an arbitrary completion thread.
    if (!state.info) {
      return DesktopExitFailed(state, E_NOINTERFACE, "missing-async-info");
    }
    AsyncStatus status;
    auto hr = state.info->get_Status(&status);
    if (FAILED(hr)) {
      return DesktopExitFailed(state, hr, "read-queue-status");
    }
    if (status == AsyncStatus::Started) return S_OK;
    if (status == AsyncStatus::Canceled) {
      return DesktopExitFailed(state, E_ABORT, "queue-shutdown-canceled");
    }
    if (status == AsyncStatus::Error) {
      HRESULT error = E_FAIL;
      hr = state.info->get_ErrorCode(&error);
      return DesktopExitFailed(state, FAILED(hr) ? hr : error,
                               "queue-shutdown-error");
    }
    if (status != AsyncStatus::Completed) {
      return DesktopExitFailed(state, E_UNEXPECTED, "unknown-queue-status");
    }
    hr = state.action->GetResults();
    if (FAILED(hr)) {
      return DesktopExitFailed(state, hr, "queue-shutdown-results");
    }
    hr = state.info->Close();
    if (FAILED(hr)) {
      return DesktopExitFailed(state, hr, "close-queue-action");
    }
  }

  state.info = nullptr;
  state.action = nullptr;
  controller = nullptr;
  rohelper.reset();
  state.ready = true;
  *ready = true;
  debugLog("Baha desktop exit: queue and WinRT resources released on STA");
  return S_OK;
}

// Completion may be delivered synchronously and, on a failed environment
// creation, the upstream helper may report failure more than once.
struct DesktopPendingCreation {
  explicit DesktopPendingCreation(std::shared_ptr<DesktopExitState> value)
      : state(std::move(value)) {
    ++state->pending_creates;
  }
  bool CompleteOnce() {
    if (completed) return false;
    completed = true;
    return true;
  }
  void Release() {
    if (counted) {
      counted = false;
      --state->pending_creates;
    }
  }
  std::shared_ptr<DesktopExitState> state;
  bool completed = false;
  bool counted = true;
};

struct DesktopCreationCompletion {
  std::shared_ptr<DesktopPendingCreation> pending;
  ~DesktopCreationCompletion() { pending->Release(); }
};

HRESULT CancelDesktopCreation(
    HWND window, wil::com_ptr<ICoreWebView2Controller>& controller,
    wil::com_ptr<ICoreWebView2CompositionController>& composition,
    wil::com_ptr<ICoreWebView2Environment>& environment) {
  // Close the controller while its parent HWND and the STA are still alive.
  auto hr = controller ? controller->Close() : S_OK;
  composition = nullptr;
  controller = nullptr;
  environment = nullptr;
  if (IsWindow(window) && !DestroyWindow(window) && SUCCEEDED(hr)) {
    const auto error = GetLastError();
    hr = error ? HRESULT_FROM_WIN32(error) : E_FAIL;
  }
  return hr;
}
}  // namespace
