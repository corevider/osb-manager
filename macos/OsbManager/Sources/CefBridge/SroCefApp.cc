#include "SroCefApp.h"

#include <unistd.h>

#include <string>

#include "SroCefMessages.h"
#include "include/cef_command_line.h"
#include "include/cef_process_message.h"

namespace sro {

namespace {

bool IsGameUrl(const std::string& url) {
  const std::string origin = kGameOrigin;
  if (url.compare(0, origin.size(), origin) != 0) {
    return false;
  }
  if (url.size() == origin.size()) {
    return true;
  }
  const char next = url[origin.size()];
  return next == '/' || next == '?' || next == '#';
}

class PostHandler : public CefV8Handler {
 public:
  bool Execute(const CefString& name,
               CefRefPtr<CefV8Value> object,
               const CefV8ValueList& arguments,
               CefRefPtr<CefV8Value>& retval,
               CefString& exception) override {
    if (arguments.size() != 1 || !arguments[0]->IsString()) {
      return true;
    }
    const CefString text = arguments[0]->GetStringValue();
    if (text.length() > kMaxPageMessageLength) {
      return true;
    }
    CefRefPtr<CefV8Context> context = CefV8Context::GetCurrentContext();
    CefRefPtr<CefFrame> frame = context ? context->GetFrame() : nullptr;
    if (!frame || !frame->IsMain() || !IsGameUrl(frame->GetURL())) {
      return true;
    }
    CefRefPtr<CefProcessMessage> message =
        CefProcessMessage::Create(kPageToAppMessage);
    message->GetArgumentList()->SetString(0, text);
    frame->SendProcessMessage(PID_BROWSER, message);
    return true;
  }

 private:
  IMPLEMENT_REFCOUNTING(PostHandler);
};

void AppendDisabledFeature(CefRefPtr<CefCommandLine> command_line,
                           const std::string& feature) {
  const char kSwitch[] = "disable-features";
  if (command_line->HasSwitch(kSwitch)) {
    command_line->AppendSwitchWithValue(
        kSwitch,
        command_line->GetSwitchValue(kSwitch).ToString() + "," + feature);
  } else {
    command_line->AppendSwitchWithValue(kSwitch, feature);
  }
}

}

void SroCefApp::OnBeforeCommandLineProcessing(
    const CefString& process_type,
    CefRefPtr<CefCommandLine> command_line) {
  if (!process_type.empty()) {
    return;
  }
  command_line->AppendSwitch("disable-background-timer-throttling");
  command_line->AppendSwitch("disable-renderer-backgrounding");
  command_line->AppendSwitch("disable-backgrounding-occluded-windows");
  command_line->AppendSwitch("use-mock-keychain");
  AppendDisabledFeature(command_line, "IntensiveWakeUpThrottling");
}

void SroCefApp::OnContextInitialized() {
  if (context_initialized_callback_) {
    context_initialized_callback_();
  }
}

void SroCefApp::OnBrowserCreated(CefRefPtr<CefBrowser> browser,
                                 CefRefPtr<CefDictionaryValue> extra_info) {
  auto existing = browsers_.find(browser->GetIdentifier());
  if (existing != browsers_.end()) {
    existing->second.owner = browser;
    return;
  }
  BrowserState state;
  state.owner = browser;
  if (extra_info) {
    if (extra_info->HasKey(kExtraInfoAllowEvaluate)) {
      state.allow_evaluate = extra_info->GetBool(kExtraInfoAllowEvaluate);
    }
    if (extra_info->HasKey(kExtraInfoScripts)) {
      CefRefPtr<CefListValue> list = extra_info->GetList(kExtraInfoScripts);
      for (size_t index = 0; list && index < list->GetSize(); ++index) {
        state.scripts.push_back(list->GetString(index));
      }
    }
  }
  browsers_[browser->GetIdentifier()] = state;
}

void SroCefApp::OnBrowserDestroyed(CefRefPtr<CefBrowser> browser) {
  auto found = browsers_.find(browser->GetIdentifier());
  if (found != browsers_.end() && found->second.owner && found->second.owner->IsSame(browser)) {
    browsers_.erase(found);
  }
}

void SroCefApp::OnContextCreated(CefRefPtr<CefBrowser> browser,
                                 CefRefPtr<CefFrame> frame,
                                 CefRefPtr<CefV8Context> context) {
  if (frame->IsMain()) {
    CefRefPtr<CefProcessMessage> info =
        CefProcessMessage::Create(kRendererInfoMessage);
    info->GetArgumentList()->SetInt(0, static_cast<int>(getpid()));
    frame->SendProcessMessage(PID_BROWSER, info);
  }
  if (!frame->IsMain() || !IsGameUrl(frame->GetURL())) {
    return;
  }
  auto found = browsers_.find(browser->GetIdentifier());
  if (found == browsers_.end() || found->second.scripts.empty()) {
    return;
  }
  RunScripts(frame, context, found->second);
}

void SroCefApp::OnContextReleased(CefRefPtr<CefBrowser> browser,
                                  CefRefPtr<CefFrame> frame,
                                  CefRefPtr<CefV8Context> context) {
  frames_.erase(frame->GetIdentifier().ToString());
}

void SroCefApp::RunScripts(CefRefPtr<CefFrame> frame,
                           CefRefPtr<CefV8Context> context,
                           const BrowserState& state) {
  context->Enter();
  CefRefPtr<CefV8Value> result;
  CefRefPtr<CefV8Exception> exception;

  if (!context->Eval(state.scripts[0], "sro-shim.js", 1, result, exception) ||
      !result || !result->IsFunction()) {
    ReportScriptError(frame, "sro-shim.js",
                      exception ? exception->GetMessage() : "no function");
    context->Exit();
    return;
  }
  CefRefPtr<CefV8Value> post =
      CefV8Value::CreateFunction("post", new PostHandler());
  CefV8ValueList arguments;
  arguments.push_back(post);
  CefRefPtr<CefV8Value> dispatch = result->ExecuteFunction(nullptr, arguments);
  if (!dispatch || !dispatch->IsFunction()) {
    ReportScriptError(frame, "sro-shim.js", "the shim returned no dispatch");
    context->Exit();
    return;
  }
  frames_[frame->GetIdentifier().ToString()] = {context, dispatch};

  for (size_t index = 1; index < state.scripts.size(); ++index) {
    CefRefPtr<CefV8Value> ignored;
    CefRefPtr<CefV8Exception> error;
    const CefString name = "sro-script-" + std::to_string(index) + ".js";
    if (!context->Eval(state.scripts[index], name, 1, ignored, error)) {
      ReportScriptError(frame, name,
                        error ? error->GetMessage() : "unknown error");
    }
  }
  context->Exit();
}

void SroCefApp::ReportScriptError(CefRefPtr<CefFrame> frame,
                                  const CefString& name,
                                  const CefString& text) {
  CefRefPtr<CefProcessMessage> message =
      CefProcessMessage::Create(kScriptErrorMessage);
  message->GetArgumentList()->SetString(0, name);
  message->GetArgumentList()->SetString(1, text);
  frame->SendProcessMessage(PID_BROWSER, message);
}

bool SroCefApp::OnProcessMessageReceived(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    CefProcessId source_process,
    CefRefPtr<CefProcessMessage> message) {
  const std::string name = message->GetName();
  CefRefPtr<CefListValue> arguments = message->GetArgumentList();

  if (name == kAppToPageMessage) {
    auto found = frames_.find(frame->GetIdentifier().ToString());
    if (found == frames_.end() || !found->second.context->IsValid()) {
      return true;
    }
    CefRefPtr<CefV8Context> context = found->second.context;
    context->Enter();
    CefV8ValueList values;
    values.push_back(CefV8Value::CreateString(arguments->GetString(0)));
    found->second.dispatch->ExecuteFunction(nullptr, values);
    context->Exit();
    return true;
  }

  if (name == kScriptsMessage) {
    BrowserState& state = browsers_[browser->GetIdentifier()];
    state.scripts.clear();
    for (size_t index = 0; index < arguments->GetSize(); ++index) {
      state.scripts.push_back(arguments->GetString(index));
    }
    return true;
  }

  if (name == kEvaluateMessage) {
    Evaluate(browser, frame, message);
    return true;
  }
  return false;
}

void SroCefApp::Evaluate(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefFrame> frame,
                         CefRefPtr<CefProcessMessage> message) {
  CefRefPtr<CefListValue> arguments = message->GetArgumentList();
  const int request = arguments->GetInt(0);
  CefRefPtr<CefProcessMessage> reply =
      CefProcessMessage::Create(kEvaluateResultMessage);
  CefRefPtr<CefListValue> out = reply->GetArgumentList();
  out->SetInt(0, request);

  auto state = browsers_.find(browser->GetIdentifier());
  CefRefPtr<CefV8Context> context = frame->GetV8Context();
  if (state == browsers_.end() || !state->second.allow_evaluate || !context) {
    out->SetBool(1, false);
    out->SetString(2, "evaluation is not available");
    frame->SendProcessMessage(PID_BROWSER, reply);
    return;
  }

  const std::string wrapped =
      "(function(){var r=(function(){" + arguments->GetString(1).ToString() +
      "\n})();return r===undefined?'null':JSON.stringify(r);})()";
  CefRefPtr<CefV8Value> value;
  CefRefPtr<CefV8Exception> exception;
  context->Enter();
  const bool ok =
      context->Eval(wrapped, "sro-evaluate.js", 1, value, exception);
  out->SetBool(1, ok);
  if (ok && value && value->IsString()) {
    out->SetString(2, value->GetStringValue());
  } else if (!ok && exception) {
    out->SetString(2, exception->GetMessage());
  } else {
    out->SetString(2, "null");
  }
  context->Exit();
  frame->SendProcessMessage(PID_BROWSER, reply);
}

}
