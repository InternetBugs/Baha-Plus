// Exercise the production creation method with real WebView2 interfaces and
// controlled HRESULT/callback delivery. No browser process or engine is used.
namespace {
struct TestEnvironmentFactory {
  HRESULT start_result = S_OK;
  HRESULT callback_result = S_OK;
  bool synchronous = true;
  Microsoft::WRL::ComPtr<ICoreWebView2Environment> environment;
  Microsoft::WRL::ComPtr<
      ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler> callback;
} test_environment_factory;

HRESULT StartTestEnvironment(
    PCWSTR, PCWSTR, ICoreWebView2EnvironmentOptions*,
    ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler* handler) {
  test_environment_factory.callback = handler;
  if (test_environment_factory.synchronous) {
    handler->Invoke(test_environment_factory.callback_result,
                    test_environment_factory.environment.Get());
  }
  return test_environment_factory.start_result;
}
}  // namespace

#define CreateCoreWebView2EnvironmentWithOptions StartTestEnvironment
#include "webview_desktop_creation.inc"
#undef CreateCoreWebView2EnvironmentWithOptions

// These value-only constructors normally come from settings.cpp. The
// standalone test deliberately links no plugin/Flutter implementation.
InAppWebViewSettings::InAppWebViewSettings() = default;
InAppWebViewSettings::~InAppWebViewSettings() = default;

namespace {
class FakeOptions final
    : public Microsoft::WRL::RuntimeClass<
          Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
          ICoreWebView2ControllerOptions> {
 public:
  HRESULT STDMETHODCALLTYPE get_ProfileName(LPWSTR*) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE put_ProfileName(LPCWSTR) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE get_IsInPrivateModeEnabled(BOOL*) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE put_IsInPrivateModeEnabled(BOOL) override {
    return S_OK;
  }
};

class FakeEnvironment final
    : public Microsoft::WRL::RuntimeClass<
          Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
          ICoreWebView2Environment10> {
 public:
  bool modern = true;
  HRESULT start_result = E_ACCESSDENIED;
  HRESULT options_result = S_OK;
  int branch = -1;
  Microsoft::WRL::ComPtr<
      ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler>
      composition_callback;
  Microsoft::WRL::ComPtr<
      ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>
      controller_callback;

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** output) override {
    if (!modern && iid == __uuidof(ICoreWebView2Environment10)) {
      *output = nullptr;
      return E_NOINTERFACE;
    }
    if (iid == __uuidof(ICoreWebView2Environment)) {
      *output = static_cast<ICoreWebView2Environment*>(this);
    } else if (iid == __uuidof(ICoreWebView2Environment3)) {
      *output = static_cast<ICoreWebView2Environment3*>(this);
    } else {
      return RuntimeClass::QueryInterface(iid, output);
    }
    AddRef();
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE CreateCoreWebView2Controller(
      HWND, ICoreWebView2CreateCoreWebView2ControllerCompletedHandler* handler)
      override {
    branch = 0;
    controller_callback = handler;
    return start_result;
  }
  HRESULT STDMETHODCALLTYPE CreateCoreWebView2CompositionController(
      HWND,
      ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler*
          handler) override {
    branch = 1;
    composition_callback = handler;
    return start_result;
  }
  HRESULT STDMETHODCALLTYPE CreateCoreWebView2ControllerWithOptions(
      HWND, ICoreWebView2ControllerOptions*,
      ICoreWebView2CreateCoreWebView2ControllerCompletedHandler* handler)
      override {
    branch = 2;
    controller_callback = handler;
    return start_result;
  }
  HRESULT STDMETHODCALLTYPE CreateCoreWebView2CompositionControllerWithOptions(
      HWND, ICoreWebView2ControllerOptions*,
      ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler*
          handler) override {
    branch = 3;
    composition_callback = handler;
    return start_result;
  }
  HRESULT STDMETHODCALLTYPE CreateCoreWebView2ControllerOptions(
      ICoreWebView2ControllerOptions** output) override {
    if (FAILED(options_result)) return options_result;
    return Microsoft::WRL::Make<FakeOptions>().CopyTo(output);
  }
  HRESULT STDMETHODCALLTYPE CreateWebResourceResponse(
      IStream*, int, LPCWSTR, LPCWSTR, ICoreWebView2WebResourceResponse**)
      override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE get_BrowserVersionString(LPWSTR*) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE add_NewBrowserVersionAvailable(
      ICoreWebView2NewBrowserVersionAvailableEventHandler*,
      EventRegistrationToken*) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE remove_NewBrowserVersionAvailable(
      EventRegistrationToken) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE CreateWebResourceRequest(
      LPCWSTR, LPCWSTR, IStream*, LPCWSTR, ICoreWebView2WebResourceRequest**)
      override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE CreateCoreWebView2PointerInfo(
      ICoreWebView2PointerInfo**) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE GetAutomationProviderForWindow(HWND, IUnknown**)
      override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE add_BrowserProcessExited(
      ICoreWebView2BrowserProcessExitedEventHandler*, EventRegistrationToken*)
      override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE remove_BrowserProcessExited(
      EventRegistrationToken) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE CreatePrintSettings(ICoreWebView2PrintSettings**)
      override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE get_UserDataFolder(LPWSTR*) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE add_ProcessInfosChanged(
      ICoreWebView2ProcessInfosChangedEventHandler*, EventRegistrationToken*)
      override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE remove_ProcessInfosChanged(EventRegistrationToken)
      override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE GetProcessInfos(ICoreWebView2ProcessInfoCollection**)
      override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE CreateContextMenuItem(
      LPCWSTR, IStream*, COREWEBVIEW2_CONTEXT_MENU_ITEM_KIND,
      ICoreWebView2ContextMenuItem**) override {
    return E_NOTIMPL;
  }

  void CompleteNull(HRESULT hr) {
    if (composition_callback) composition_callback->Invoke(hr, nullptr);
    if (controller_callback) controller_callback->Invoke(hr, nullptr);
  }
  void ClearCallbacks() {
    composition_callback.Reset();
    controller_callback.Reset();
  }
};

struct CreationFixture {
  const std::shared_ptr<DesktopExitState> state =
      std::make_shared<DesktopExitState>();
  const std::shared_ptr<DesktopPendingCreation> pending =
      std::make_shared<DesktopPendingCreation>(state);
  Microsoft::WRL::ComPtr<FakeEnvironment> environment =
      Microsoft::WRL::Make<FakeEnvironment>();
  int completions = 0;

  CreationFixture() {
    test_environment_factory = {};
    environment.CopyTo(test_environment_factory.environment.ReleaseAndGetAddressOf());
  }
  ~CreationFixture() {
    environment->ClearCallbacks();
    test_environment_factory = {};
  }
  void Start(bool surface) {
    InAppWebView::createInAppWebViewEnv(
        nullptr, surface, nullptr, std::make_shared<InAppWebViewSettings>(),
        [this](wil::com_ptr<ICoreWebView2Environment> env,
               wil::com_ptr<ICoreWebView2Controller> controller,
               wil::com_ptr<ICoreWebView2CompositionController> composition) {
          ++completions;
          assert(!env && !controller && !composition);
          assert(pending->CompleteOnce());
          const DesktopCreationCompletion completion{pending};
        });
  }
  void CheckCompleted() {
    assert(completions == 1 && state->pending_creates == 0);
  }
};

int RunCreationChecks() {
  int checks = 0;
  {
    CreationFixture f;
    test_environment_factory.synchronous = false;
    test_environment_factory.start_result = E_ACCESSDENIED;
    f.Start(true);
    f.CheckCompleted();
    assert(f.environment->branch == -1);
    ++checks;
  }
  for (const auto hr : {E_ACCESSDENIED, S_OK}) {
    CreationFixture f;
    test_environment_factory.synchronous = false;
    f.Start(true);
    assert(f.completions == 0 && f.state->pending_creates == 1);
    test_environment_factory.callback->Invoke(hr, nullptr);
    f.CheckCompleted();
    test_environment_factory.callback->Invoke(E_FAIL, nullptr);
    f.CheckCompleted();
    ++checks;
  }
  for (int branch = 0; branch != 4; ++branch) {
    CreationFixture f;
    f.environment->modern = branch >= 2;
    f.Start(branch % 2 != 0);
    assert(f.environment->branch == branch);
    f.CheckCompleted();  // Immediate start failure without an async callback.
    f.environment->CompleteNull(E_FAIL);
    f.CheckCompleted();
    ++checks;
  }
  for (int branch = 0; branch != 4; ++branch) {
    for (const auto hr : {E_ACCESSDENIED, S_OK}) {
      CreationFixture f;
      f.environment->modern = branch >= 2;
      f.environment->start_result = S_OK;
      f.Start(branch % 2 != 0);
      assert(f.environment->branch == branch);
      assert(f.completions == 0 && f.state->pending_creates == 1);
      f.environment->CompleteNull(hr);
      f.CheckCompleted();
      f.environment->CompleteNull(E_FAIL);
      f.CheckCompleted();
      ++checks;
    }
  }
  {
    CreationFixture f;
    f.environment->options_result = E_FAIL;
    f.Start(true);
    assert(f.environment->branch == 1);
    f.CheckCompleted();
    ++checks;
  }
  return checks;
}
}  // namespace
