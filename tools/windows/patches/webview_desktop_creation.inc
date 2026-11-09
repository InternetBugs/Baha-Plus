// Included inside flutter_inappwebview_plugin by the pinned in_app_webview.cpp.
namespace {
using DesktopEnvironmentCompletion = std::function<void(
    wil::com_ptr<ICoreWebView2Environment>,
    wil::com_ptr<ICoreWebView2Controller>,
    wil::com_ptr<ICoreWebView2CompositionController>)>;

struct DesktopEnvironmentCreation {
  explicit DesktopEnvironmentCreation(DesktopEnvironmentCompletion value)
      : completion(std::move(value)) {}

  void Complete(wil::com_ptr<ICoreWebView2Environment> environment,
                wil::com_ptr<ICoreWebView2Controller> controller,
                wil::com_ptr<ICoreWebView2CompositionController> composition) {
    if (!completion) return;
    // Consume before invoking: a synchronous callback plus a failing return
    // value, or a duplicate async failure, must not complete the caller twice.
    auto callback = std::move(completion);
    completion = nullptr;
    callback(std::move(environment), std::move(controller),
             std::move(composition));
  }

  HRESULT Fail(HRESULT error) {
    const auto hr = FAILED(error) ? error : E_POINTER;
    failedLog(hr);
    Complete(nullptr, nullptr, nullptr);
    return hr;
  }

  HRESULT Started(HRESULT hr) {
    return FAILED(hr) ? Fail(hr) : hr;
  }

  DesktopEnvironmentCompletion completion;
};
}  // namespace

void InAppWebView::createInAppWebViewEnv(
    const HWND parentWindow, const bool& willBeSurface,
    WebViewEnvironment* webViewEnvironment,
    const std::shared_ptr<InAppWebViewSettings> initialSettings,
    DesktopEnvironmentCompletion completionHandler) {
  const auto creation =
      std::make_shared<DesktopEnvironmentCreation>(std::move(completionHandler));
  const auto callback =
      [parentWindow, willBeSurface, initialSettings, creation](
          HRESULT result,
          wil::com_ptr<ICoreWebView2Environment> env) -> HRESULT {
    if (FAILED(result) || !env) return creation->Fail(result);

    wil::com_ptr<ICoreWebView2Environment3> env3;
    wil::com_ptr<ICoreWebView2Environment10> env10;
    wil::com_ptr<ICoreWebView2ControllerOptions> options;
    if (initialSettings &&
        SUCCEEDED(env->QueryInterface(IID_PPV_ARGS(&env10))) && env10 &&
        SUCCEEDED(env10->CreateCoreWebView2ControllerOptions(&options)) &&
        options) {
      failedLog(options->put_IsInPrivateModeEnabled(initialSettings->incognito));
    } else {
      env10 = nullptr;
      options = nullptr;
      // Older WebView2 runtimes keep their existing non-options fallback.
      env->QueryInterface(IID_PPV_ARGS(&env3));
    }

    const auto composition_created =
        [creation, env](
            HRESULT hr,
            wil::com_ptr<ICoreWebView2CompositionController> composition)
            -> HRESULT {
      // Do not query a null composition controller on failure.
      if (FAILED(hr) || !composition) return creation->Fail(hr);
      auto controller = composition.try_query<ICoreWebView2Controller3>();
      if (!controller) return creation->Fail(E_NOINTERFACE);
      // Retain the queried controller with RAII, rather than leaking a raw QI
      // reference that could outlive the desktop queue shutdown.
      failedLog(controller->put_BoundsMode(
          COREWEBVIEW2_BOUNDS_MODE_USE_RAW_PIXELS));
      failedLog(controller->put_ShouldDetectMonitorScaleChanges(FALSE));
      failedLog(controller->put_RasterizationScale(1.0));
      creation->Complete(std::move(env), std::move(controller),
                         std::move(composition));
      return S_OK;
    };
    const auto controller_created =
        [creation, env](HRESULT hr,
                        wil::com_ptr<ICoreWebView2Controller> controller)
            -> HRESULT {
      if (FAILED(hr) || !controller) return creation->Fail(hr);
      creation->Complete(std::move(env), std::move(controller), nullptr);
      return S_OK;
    };

    HRESULT hr;
    if (willBeSurface && (env10 || env3)) {
      auto handler = Microsoft::WRL::Callback<
          ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler>(
          composition_created);
      hr = env10
               ? env10->CreateCoreWebView2CompositionControllerWithOptions(
                     parentWindow, options.get(), handler.Get())
               : env3->CreateCoreWebView2CompositionController(parentWindow,
                                                              handler.Get());
    } else {
      auto handler = Microsoft::WRL::Callback<
          ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
          controller_created);
      hr = env10 ? env10->CreateCoreWebView2ControllerWithOptions(
                       parentWindow, options.get(), handler.Get())
                 : env->CreateCoreWebView2Controller(parentWindow,
                                                      handler.Get());
    }
    // WebView2 need not invoke a completion handler when starting the async
    // operation itself fails. Every one of the four controller starts reaches
    // this check, so the manager's pending creation count can always finish.
    return creation->Started(hr);
  };

  const auto hr = webViewEnvironment && webViewEnvironment->getEnvironment()
                      ? callback(S_OK, webViewEnvironment->getEnvironment())
                      : CreateCoreWebView2EnvironmentWithOptions(
                            nullptr, nullptr, nullptr,
                            Microsoft::WRL::Callback<
                                ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
                                callback)
                                .Get());
  creation->Started(hr);
}
