// Standalone native regression checks. No Flutter engine or WebView is started.
// Compile with the same Windows SDK, Flutter, WebView2 and WIL include paths as
// the pinned plugin, plus /std:c++17 /EHsc; link ole32.lib runtimeobject.lib.
#include <asyncinfo.h>
#include <atomic>
#include <cassert>
#include <exception>
#include <iostream>
#include <sstream>
#include <thread>
#include <vector>
#include <windows.foundation.h>
#include <wrl.h>

#include "in_app_webview/in_app_webview_manager.h"
#include "utils/log.h"
#include "webview_desktop_retirement.h"

namespace flutter_inappwebview_plugin {
#include "webview_desktop_exit.inc"
#include "webview_desktop_creation_test.inc"

namespace {
class FakeAction final
    : public Microsoft::WRL::RuntimeClass<
          Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::WinRt>,
          ABI::Windows::Foundation::IAsyncAction, ::IAsyncInfo> {
 public:
  AsyncStatus status = AsyncStatus::Started;
  HRESULT status_result = S_OK, results_result = S_OK, close_result = S_OK;
  int results = 0, closes = 0;
  HRESULT STDMETHODCALLTYPE put_Completed(
      ABI::Windows::Foundation::IAsyncActionCompletedHandler*) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE get_Completed(
      ABI::Windows::Foundation::IAsyncActionCompletedHandler**) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE GetResults() override {
    ++results;
    return results_result;
  }
  HRESULT STDMETHODCALLTYPE get_Id(unsigned int* value) override {
    *value = 1;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE get_Status(AsyncStatus* value) override {
    *value = status;
    return status_result;
  }
  HRESULT STDMETHODCALLTYPE get_ErrorCode(HRESULT* value) override {
    *value = E_ACCESSDENIED;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE Cancel() override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE Close() override {
    ++closes;
    return close_result;
  }
};

class FakeController final
    : public Microsoft::WRL::RuntimeClass<
          Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::WinRt>,
          ABI::Windows::System::IDispatcherQueueController> {
 public:
  Microsoft::WRL::ComPtr<FakeAction> action =
      Microsoft::WRL::Make<FakeAction>();
  HRESULT start_result = S_OK;
  int starts = 0;
  HRESULT STDMETHODCALLTYPE get_DispatcherQueue(
      ABI::Windows::System::IDispatcherQueue**) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE ShutdownQueueAsync(
      ABI::Windows::Foundation::IAsyncAction** value) override {
    ++starts;
    if (FAILED(start_result)) return start_result;
    return action.CopyTo(value);
  }
};

class FakeRegistrar final : public flutter::TextureRegistrar {
 public:
  int64_t id = 7;
  int registrations = 0, unregistrations = 0;
  flutter::TextureVariant* texture = nullptr;
  bool synchronous = false;
  std::function<void()> callback;
  int64_t RegisterTexture(flutter::TextureVariant* value) override {
    ++registrations;
    texture = value;
    return id;
  }
  bool MarkTextureFrameAvailable(int64_t) override { return true; }
  void UnregisterTexture(int64_t, std::function<void()> value) override {
    ++unregistrations;
    callback = std::move(value);
    if (synchronous) callback();
  }
  bool UnregisterTexture(int64_t) override { return false; }
  void CompleteRaster() {
    std::thread worker(std::move(callback));
    worker.join();
  }
};

struct Fixture {
  DesktopExitState state;
  FakeRegistrar registrar;
  Microsoft::WRL::ComPtr<FakeController> fake =
      Microsoft::WRL::Make<FakeController>();
  winrt::com_ptr<ABI::Windows::UI::Composition::ICompositor> compositor;
  std::unique_ptr<GraphicsContext> graphics;
  winrt::com_ptr<ABI::Windows::System::IDispatcherQueueController> controller;
  std::shared_ptr<rx::RoHelper> rohelper;
  bool ready = false;

  Fixture() {
    const auto hr = fake.CopyTo(controller.put());
    assert(SUCCEEDED(hr));
  }
  HRESULT Poll() {
    return PollDesktopExit(state, &registrar, compositor, graphics, controller,
                           rohelper, &ready);
  }
  void StartQueue() {
    assert(SUCCEEDED(Poll()));
    assert(!ready && !state.graphics_released && fake->starts == 0);
    registrar.CompleteRaster();
    assert(SUCCEEDED(Poll()));
    assert(!ready && state.graphics_released && fake->starts == 1);
  }
};

struct RetiredProbe {
  DWORD owner = GetCurrentThreadId();
  int tag;
  std::vector<int>& released;
  std::function<void()> on_release;
  RetiredProbe(int value, std::vector<int>& events)
      : tag(value), released(events) {}
  ~RetiredProbe() {
    assert(GetCurrentThreadId() == owner);
    released.push_back(tag);
    if (on_release) on_release();
  }
};

auto MakeRetiredView(std::vector<int>& released) {
  auto bridge = std::make_unique<RetiredProbe>(1, released);
  auto* raw_bridge = bridge.get();
  auto texture = std::make_unique<flutter::TextureVariant>(
      flutter::PixelBufferTexture(
          [raw_bridge](size_t, size_t) -> const FlutterDesktopPixelBuffer* {
            // This raw bridge callback matches the production texture.
            assert(raw_bridge->tag == 1);
            return nullptr;
          }));
  auto view = std::make_shared<RetiredProbe>(2, released);
  return std::make_unique<DesktopRetiredView<RetiredProbe, RetiredProbe>>(
      std::move(texture), std::move(bridge), std::move(view));
}

UINT_PTR WINAPI FailRetirementTimer(HWND, UINT_PTR, UINT, TIMERPROC) {
  SetLastError(ERROR_NOT_ENOUGH_MEMORY);
  return 0;
}

UINT_PTR WINAPI FakeRetirementTimer(HWND, UINT_PTR, UINT, TIMERPROC) {
  return 101;
}

bool retirement_kill_fails = true;
BOOL WINAPI ControlledKillTimer(HWND, UINT_PTR) {
  if (!retirement_kill_fails) return TRUE;
  SetLastError(ERROR_ACCESS_DENIED);
  return FALSE;
}

int RunRetirementChecks() {
  int checks = 0;
  {
    Fixture f;
    FakeRegistrar retiring;
    std::vector<int> released;
    auto resources = MakeRetiredView(released);
    retiring.RegisterTexture(resources->texture.get());
    assert(SUCCEEDED(desktop_texture_retirement.Retire(
        &retiring, retiring.id, std::move(resources))));
    assert(SUCCEEDED(f.Poll()) && !f.ready);
    assert(f.registrar.registrations == 0 && !f.state.graphics_released);
    assert(desktop_texture_retirement.Pending() == 1 && released.empty());
    std::thread worker([&]() {
      std::get<flutter::PixelBufferTexture>(*retiring.texture)
          .CopyPixelBuffer(1, 1);
      retiring.callback();
      // Completion is a signal only; COM-bearing resources stay on STA.
      assert(released.empty());
    });
    worker.join();
    assert(released.empty());
    assert(SUCCEEDED(f.Poll()) && !f.ready);
    assert((released == std::vector<int>{1, 2}));
    assert(desktop_texture_retirement.Pending() == 0);
    assert(f.registrar.registrations == 1 && !f.state.graphics_released);
    f.registrar.CompleteRaster();
    f.fake->action->status = AsyncStatus::Completed;
    assert(SUCCEEDED(f.Poll()) && f.ready);
    ++checks;
  }
  {
    FakeRegistrar registrar;
    std::vector<int> released;
    auto resources = MakeRetiredView(released);
    registrar.RegisterTexture(resources->texture.get());
    assert(SUCCEEDED(desktop_texture_retirement.Retire(
        &registrar, registrar.id, std::move(resources))));
    registrar.CompleteRaster();
    // Ordinary navigation must reclaim through the real owner-thread timer,
    // without any manager shutdown poll.
    const auto deadline = GetTickCount64() + 2000;
    while (released.empty() && GetTickCount64() < deadline) {
      MsgWaitForMultipleObjects(0, nullptr, FALSE, 25, QS_ALLINPUT);
      MSG message;
      while (PeekMessage(&message, nullptr, 0, 0, PM_REMOVE)) {
        TranslateMessage(&message);
        DispatchMessage(&message);
      }
    }
    assert((released == std::vector<int>{1, 2}));
    assert(desktop_texture_retirement.Pending() == 0);
    ++checks;
  }
  {
    DesktopTextureRetirement queue(&DesktopRetirementTimer,
                                   &FailRetirementTimer);
    FakeRegistrar registrar;
    std::vector<int> released;
    auto resources = MakeRetiredView(released);
    registrar.RegisterTexture(resources->texture.get());
    assert(FAILED(queue.Retire(&registrar, registrar.id, std::move(resources))));
    assert(FAILED(queue.Drain()) && queue.Pending() == 1 && released.empty());
    HRESULT other_thread = S_OK;
    std::thread worker([&]() { other_thread = queue.Drain(); });
    worker.join();
    assert(other_thread == RPC_E_WRONG_THREAD && released.empty());
    registrar.CompleteRaster();
    // A platform poll can still safely drain after timer allocation failed.
    assert(SUCCEEDED(queue.Drain()) && queue.Pending() == 0);
    assert((released == std::vector<int>{1, 2}));
    ++checks;
  }
  {
    FakeRegistrar registrar;
    registrar.synchronous = true;
    std::vector<int> released;
    auto resources = MakeRetiredView(released);
    const auto signal = resources->raster_ready;
    registrar.RegisterTexture(resources->texture.get());
    assert(FAILED(desktop_texture_retirement.Retire(
        &registrar, registrar.id, std::move(resources))));
    Fixture f;
    assert(FAILED(f.Poll()) && !f.ready);
    assert(f.registrar.registrations == 0 && !f.state.graphics_released);
    assert(desktop_texture_retirement.Pending() == 1 && released.empty());
    // Test-only cleanup after proving the failed callback cannot release/ACK.
    signal->store(1);
    assert(SUCCEEDED(desktop_texture_retirement.Drain()));
    ++checks;
  }
  {
    Fixture f;
    FakeRegistrar registrar;
    std::vector<int> released;
    bool reentered = false;
    auto resources = MakeRetiredView(released);
    resources->bridge->on_release = [&]() {
      assert(desktop_texture_retirement.Pending() != 0);
      assert(SUCCEEDED(f.Poll()) && !f.ready);
      assert(f.registrar.registrations == 0 && !f.state.graphics_released);
      reentered = true;
    };
    registrar.RegisterTexture(resources->texture.get());
    assert(SUCCEEDED(desktop_texture_retirement.Retire(
        &registrar, registrar.id, std::move(resources))));
    registrar.CompleteRaster();
    assert(SUCCEEDED(f.Poll()) && !f.ready && reentered);
    assert((released == std::vector<int>{1, 2}));
    assert(f.registrar.registrations == 1);
    f.registrar.CompleteRaster();
    f.fake->action->status = AsyncStatus::Completed;
    assert(SUCCEEDED(f.Poll()) && f.ready);
    ++checks;
  }
  {
    DesktopTextureRetirement queue(
        &DesktopRetirementTimer, &FakeRetirementTimer, &ControlledKillTimer);
    FakeRegistrar registrar;
    std::vector<int> released;
    auto resources = MakeRetiredView(released);
    registrar.RegisterTexture(resources->texture.get());
    assert(SUCCEEDED(queue.Retire(&registrar, registrar.id, std::move(resources))));
    registrar.CompleteRaster();
    assert(FAILED(queue.Drain()));
    assert(queue.Pending() == 0 && (released == std::vector<int>{1, 2}));
    retirement_kill_fails = false;
    assert(SUCCEEDED(queue.Drain()));
    ++checks;
  }
  return checks;
}

void RunChecks() {
  {
    Fixture f;
    assert(SUCCEEDED(CheckDesktopExitThread(f.state)));
    HRESULT other_thread = S_OK;
    std::thread worker([&]() {
      other_thread = CheckDesktopExitThread(f.state);
    });
    worker.join();
    assert(other_thread == RPC_E_WRONG_THREAD);
    f.StartQueue();
    for (int i = 0; i < 3; ++i) {
      assert(SUCCEEDED(f.Poll()) && !f.ready);
    }
    assert(f.fake->starts == 1 && f.registrar.registrations == 1);
    f.fake->action->status = AsyncStatus::Completed;
    assert(SUCCEEDED(f.Poll()) && f.ready);
    assert(f.fake->action->results == 1 && f.fake->action->closes == 1);
    assert(!f.state.info && !f.state.action && !f.controller && !f.rohelper);
    assert(SUCCEEDED(f.Poll()) && f.ready);
    assert(f.fake->starts == 1 && f.fake->action->results == 1);
  }
  for (const auto status : {AsyncStatus::Error, AsyncStatus::Canceled}) {
    Fixture f;
    f.StartQueue();
    f.fake->action->status = status;
    assert(FAILED(f.Poll()) && !f.ready);
    assert(f.fake->action->results == 0 && f.fake->action->closes == 0);
    f.fake->action->status = AsyncStatus::Completed;
    assert(FAILED(f.Poll()) && !f.ready && f.fake->starts == 1);
  }
  for (int failure = 0; failure < 4; ++failure) {
    Fixture f;
    if (failure == 0) f.fake->start_result = E_FAIL;
    assert(SUCCEEDED(f.Poll()) && !f.ready);
    f.registrar.CompleteRaster();
    if (failure == 1) f.fake->action->status_result = E_FAIL;
    if (failure == 2) f.fake->action->results_result = E_FAIL;
    if (failure == 3) f.fake->action->close_result = E_FAIL;
    f.fake->action->status = AsyncStatus::Completed;
    assert(FAILED(f.Poll()) && !f.ready);
    assert(FAILED(f.Poll()) && !f.ready && f.fake->starts == 1);
  }
  {
    Fixture f;
    assert(SUCCEEDED(f.Poll()) && !f.ready);
    f.registrar.callback();  // Engine's synchronous post-failure fallback.
    assert(FAILED(f.Poll()) && !f.ready && f.fake->starts == 0);
  }
  {
    Fixture f;
    f.registrar.id = -1;
    assert(FAILED(f.Poll()) && !f.ready && f.fake->starts == 0);
  }
  {
    Fixture f;
    f.controller = nullptr;  // Plugin initialization never created a queue.
    assert(SUCCEEDED(f.Poll()) && !f.ready);
    f.registrar.CompleteRaster();
    assert(SUCCEEDED(f.Poll()) && f.ready && f.fake->starts == 0);
  }
  {
    const auto state = std::make_shared<DesktopExitState>();
    const auto first = std::make_shared<DesktopPendingCreation>(state);
    const auto second = std::make_shared<DesktopPendingCreation>(state);
    assert(state->pending_creates == 2);
    assert(first->CompleteOnce() && !first->CompleteOnce());
    {
      const DesktopCreationCompletion completion{first};
    }
    first->Release();
    assert(state->pending_creates == 1);
    {
      const DesktopCreationCompletion completion{second};
    }
    assert(state->pending_creates == 0);
  }
  const auto checks = 12 + RunRetirementChecks() + RunCreationChecks();
  std::cout << checks << " native desktop shutdown checks passed." << std::endl;
}
}  // namespace
}  // namespace flutter_inappwebview_plugin

int main() {
  _set_error_mode(_OUT_TO_STDERR);
  const auto hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(hr)) return 2;
  flutter_inappwebview_plugin::RunChecks();
  CoUninitialize();
  return 0;
}
