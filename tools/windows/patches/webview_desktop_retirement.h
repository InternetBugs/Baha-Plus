// Desktop-only texture retirement for the pinned Windows plugin.
#pragma once

#include <flutter/texture_registrar.h>
#include <windows.h>

#include <atomic>
#include <cassert>
#include <list>
#include <memory>
#include <utility>

namespace flutter_inappwebview_plugin {

struct DesktopRetiredTexture {
  virtual ~DesktopRetiredTexture() = default;
  std::shared_ptr<std::atomic<int>> raster_ready =
      std::make_shared<std::atomic<int>>(0);
};

template <typename Bridge, typename View>
struct DesktopRetiredView final : DesktopRetiredTexture {
  DesktopRetiredView(std::unique_ptr<flutter::TextureVariant> texture_value,
                     std::unique_ptr<Bridge> bridge_value,
                     std::shared_ptr<View> view_value)
      : texture(std::move(texture_value)),
        bridge(std::move(bridge_value)),
        view(std::move(view_value)) {}

  ~DesktopRetiredView() override {
    // Unregistration has finished. Destroy the capture/texture bridge before
    // its view, while the global graphics context and owning STA still exist.
    texture.reset();
    bridge.reset();
    view.reset();
  }

  std::unique_ptr<flutter::TextureVariant> texture;
  std::unique_ptr<Bridge> bridge;
  std::shared_ptr<View> view;
};

class DesktopTextureRetirement {
 public:
  using SetTimerFunction = decltype(&::SetTimer);
  using KillTimerFunction = decltype(&::KillTimer);

  explicit DesktopTextureRetirement(
      TIMERPROC timer_callback, SetTimerFunction set_timer = &::SetTimer,
      KillTimerFunction kill_timer = &::KillTimer)
      : timer_callback_(timer_callback),
        set_timer_(set_timer),
        kill_timer_(kill_timer) {}
  DesktopTextureRetirement(const DesktopTextureRetirement&) = delete;
  DesktopTextureRetirement& operator=(const DesktopTextureRetirement&) = delete;
  ~DesktopTextureRetirement() { StopTimer(); }

  // Only the platform STA owns this queue. The engine's unregister callback
  // captures the atomic alone, never a holder or a COM-bearing shared_ptr.
  HRESULT Retire(flutter::TextureRegistrar* registrar, int64_t texture_id,
                 std::unique_ptr<DesktopRetiredTexture> resources) {
    assert(GetCurrentThreadId() == thread_);
    const auto signal = resources->raster_ready;
    resources_.push_back(std::move(resources));
    if (texture_id < 0) {
      // RegisterTexture failed: the engine never owned this texture.
      signal->store(1, std::memory_order_release);
    } else {
      const auto owner = thread_;
      registrar->UnregisterTexture(texture_id, [signal, owner]() {
        // The pinned engine calls back inline if posting its raster task
        // fails. Such a callback cannot establish a raster drain.
        signal->store(GetCurrentThreadId() == owner ? -1 : 1,
                      std::memory_order_release);
      });
    }
    return Drain();
  }

  HRESULT Drain() {
    if (GetCurrentThreadId() != thread_) return RPC_E_WRONG_THREAD;
    if (draining_) return S_OK;
    draining_ = true;
    HRESULT result = S_OK;
    for (auto it = resources_.begin(); it != resources_.end();) {
      const auto ready =
          (*it)->raster_ready->load(std::memory_order_acquire);
      if (ready < 0) {
        result = E_FAIL;
        ++it;
      } else if (ready == 0) {
        ++it;
      } else {
        auto released = std::move(*it);
        it = resources_.erase(it);
        // COM teardown can pump messages. A reentrant shutdown poll must
        // still see this holder as pending until its destructor returns.
        ++releasing_;
        released.reset();
        --releasing_;
      }
    }
    draining_ = false;
    if (Pending() == 0) {
      const auto hr = StopTimer();
      if (FAILED(hr)) result = hr;
    } else if (!timer_) {
      SetLastError(ERROR_SUCCESS);
      timer_ = set_timer_(nullptr, 0, 16, timer_callback_);
      if (!timer_ && SUCCEEDED(result)) {
        const auto error = GetLastError();
        result = error ? HRESULT_FROM_WIN32(error) : E_FAIL;
      }
    }
    return result;
  }

  size_t Pending() const { return resources_.size() + releasing_; }

  void OnTimer(UINT_PTR timer) {
    // KillTimer does not remove an already queued WM_TIMER.
    if (timer != timer_) return;
    const auto hr = Drain();
    if (FAILED(hr)) {
      OutputDebugStringW(L"Baha desktop exit: texture retirement pending/error\n");
    }
  }

 private:
  HRESULT StopTimer() {
    if (timer_) {
      SetLastError(ERROR_SUCCESS);
      if (!kill_timer_(nullptr, timer_)) {
        const auto error = GetLastError();
        return error ? HRESULT_FROM_WIN32(error) : E_FAIL;
      }
      timer_ = 0;
    }
    return S_OK;
  }

  const DWORD thread_ = GetCurrentThreadId();
  const TIMERPROC timer_callback_;
  const SetTimerFunction set_timer_;
  const KillTimerFunction kill_timer_;
  UINT_PTR timer_ = 0;
  bool draining_ = false;
  size_t releasing_ = 0;
  std::list<std::unique_ptr<DesktopRetiredTexture>> resources_;
};

inline void CALLBACK DesktopRetirementTimer(HWND, UINT, UINT_PTR, DWORD);

// C++17 inline TLS shares one queue between manager.cpp and platform_view.cc
// on the platform thread. No registry is accessed from the raster callback.
inline thread_local DesktopTextureRetirement desktop_texture_retirement(
    &DesktopRetirementTimer);

inline void CALLBACK DesktopRetirementTimer(HWND, UINT, UINT_PTR timer, DWORD) {
  desktop_texture_retirement.OnTimer(timer);
}

}  // namespace flutter_inappwebview_plugin
