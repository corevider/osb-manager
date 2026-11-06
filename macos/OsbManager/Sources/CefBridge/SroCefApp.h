#pragma once

#include <functional>
#include <map>
#include <string>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_render_process_handler.h"
#include "include/cef_v8.h"

namespace sro {

class SroCefApp : public CefApp,
                  public CefBrowserProcessHandler,
                  public CefRenderProcessHandler {
 public:
  SroCefApp() = default;

  void OnBeforeCommandLineProcessing(
      const CefString& process_type,
      CefRefPtr<CefCommandLine> command_line) override;
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }
  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override {
    return this;
  }

  void OnContextInitialized() override;
  void SetContextInitializedCallback(std::function<void()> callback) {
    context_initialized_callback_ = std::move(callback);
  }

  void OnBrowserCreated(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefDictionaryValue> extra_info) override;
  void OnBrowserDestroyed(CefRefPtr<CefBrowser> browser) override;
  void OnContextCreated(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefV8Context> context) override;
  void OnContextReleased(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefFrame> frame,
                         CefRefPtr<CefV8Context> context) override;
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId source_process,
                                CefRefPtr<CefProcessMessage> message) override;

 private:
  struct BrowserState {
    std::vector<CefString> scripts;
    bool allow_evaluate = false;
    CefRefPtr<CefBrowser> owner;
  };

  struct FrameState {
    CefRefPtr<CefV8Context> context;
    CefRefPtr<CefV8Value> dispatch;
  };

  void RunScripts(CefRefPtr<CefFrame> frame,
                  CefRefPtr<CefV8Context> context,
                  const BrowserState& state);
  void ReportScriptError(CefRefPtr<CefFrame> frame,
                         const CefString& name,
                         const CefString& text);
  void Evaluate(CefRefPtr<CefBrowser> browser,
                CefRefPtr<CefFrame> frame,
                CefRefPtr<CefProcessMessage> message);

  std::function<void()> context_initialized_callback_;
  std::map<int, BrowserState> browsers_;
  std::map<std::string, FrameState> frames_;

  IMPLEMENT_REFCOUNTING(SroCefApp);
  DISALLOW_COPY_AND_ASSIGN(SroCefApp);
};

}
