#import "SroCefBridge.h"

#include <crt_externs.h>

#include <memory>

#include "SroCefApp.h"
#include "SroCefMessages.h"
#include "SroCefPackInterception.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_parser.h"
#include "include/cef_version.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"

namespace {

std::unique_ptr<CefScopedLibraryLoader> g_library_loader;

NSString* ToNSString(const CefString& value) {
  return [NSString stringWithUTF8String:value.ToString().c_str()];
}

CefString ToCefString(NSString* value) {
  return CefString(std::string(value.UTF8String ?: ""));
}

}

@implementation SroCefApplication {
  BOOL _handlingSendEvent;
}

- (BOOL)isHandlingSendEvent {
  return _handlingSendEvent;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  _handlingSendEvent = handlingSendEvent;
}

- (void)sendEvent:(NSEvent*)event {
  CefScopedSendingEvent sendingEventScoper;
  [super sendEvent:event];
}

- (void)terminate:(id)sender {
  if (self.terminationHandler) {
    self.terminationHandler();
  } else {
    [super terminate:sender];
  }
}

@end

@implementation SroCefRuntime

+ (BOOL)loadFramework {
  g_library_loader = std::make_unique<CefScopedLibraryLoader>();
  return g_library_loader->LoadInMain();
}

+ (BOOL)initializeWithRootCachePath:(NSString*)rootCachePath logFile:(NSString*)logFile ready:(void (^)(void))ready {
  CefMainArgs main_args(*_NSGetArgc(), *_NSGetArgv());
  CefSettings settings;
  settings.no_sandbox = false;
  settings.log_severity = LOGSEVERITY_WARNING;
  CefString(&settings.root_cache_path) = ToCefString(rootCachePath);
  CefString(&settings.log_file) = ToCefString(logFile);
  CefRefPtr<sro::SroCefApp> app(new sro::SroCefApp());
  void (^readyCopy)(void) = [ready copy];
  app->SetContextInitializedCallback([readyCopy]() { readyCopy(); });
  return CefInitialize(main_args, settings, app.get(), nullptr);
}

+ (void)runMessageLoop {
  CefRunMessageLoop();
}

+ (void)quitMessageLoop {
  CefQuitMessageLoop();
}

+ (void)shutdown {
  CefShutdown();
}

+ (NSString*)cefVersion {
  return [NSString stringWithUTF8String:CEF_VERSION];
}

+ (void)setPackProvider:(id<SroCefPackProvider>)provider {
  sro::SetPackProvider(provider);
}

@end

@class SroCefBrowser;

@interface SroCefBrowser ()
- (void)handleDevToolsResult:(int)messageId success:(BOOL)success base64:(NSString*)base64;
@end

namespace {

class SroDevToolsObserver : public CefDevToolsMessageObserver {
 public:
  explicit SroDevToolsObserver(SroCefBrowser* owner) : owner_(owner) {}

  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser,
                              int message_id,
                              bool success,
                              const void* result,
                              size_t result_size) override {
    NSString* base64 = @"";
    if (success && result && result_size > 0) {
      CefRefPtr<CefValue> parsed = CefParseJSON(result, result_size, JSON_PARSER_RFC);
      if (parsed && parsed->GetType() == VTYPE_DICTIONARY) {
        base64 = ToNSString(parsed->GetDictionary()->GetString("data"));
      }
    }
    [owner_ handleDevToolsResult:message_id success:success base64:base64];
  }

 private:
  __weak SroCefBrowser* owner_;

  IMPLEMENT_REFCOUNTING(SroDevToolsObserver);
};

class SroClient : public CefClient,
                  public CefLifeSpanHandler,
                  public CefLoadHandler,
                  public CefDisplayHandler,
                  public CefRequestHandler {
 public:
  explicit SroClient(SroCefBrowser* owner) : owner_(owner) {}

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request,
      bool is_navigation,
      bool is_download,
      const CefString& request_initiator,
      bool& disable_default_handling) override {
    return sro::CreatePackRequestHandler(request, "client");
  }

  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId source_process,
                                CefRefPtr<CefProcessMessage> message) override;

  bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     int popup_id,
                     const CefString& target_url,
                     const CefString& target_frame_name,
                     WindowOpenDisposition target_disposition,
                     bool user_gesture,
                     const CefPopupFeatures& popupFeatures,
                     CefWindowInfo& windowInfo,
                     CefRefPtr<CefClient>& client,
                     CefBrowserSettings& settings,
                     CefRefPtr<CefDictionaryValue>& extra_info,
                     bool* no_javascript_access) override;
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  bool DoClose(CefRefPtr<CefBrowser> browser) override;
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;
  void OnLoadEnd(CefRefPtr<CefBrowser> browser,
                 CefRefPtr<CefFrame> frame,
                 int httpStatusCode) override;
  void OnLoadError(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   ErrorCode errorCode,
                   const CefString& errorText,
                   const CefString& failedUrl) override;
  bool OnConsoleMessage(CefRefPtr<CefBrowser> browser,
                        cef_log_severity_t level,
                        const CefString& message,
                        const CefString& source,
                        int line) override;
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                 TerminationStatus status,
                                 int error_code,
                                 const CefString& error_string) override;

 private:
  __weak SroCefBrowser* owner_;

  IMPLEMENT_REFCOUNTING(SroClient);
};

}

@interface SroCefBrowser ()

- (void)attachBrowser:(CefRefPtr<CefBrowser>)browser;
- (void)handlePageMessage:(NSString*)json mainFrame:(BOOL)mainFrame url:(NSString*)url;
- (void)handleEvaluateResult:(int)request ok:(BOOL)ok text:(NSString*)text;
- (void)handleScriptError:(NSString*)description;
- (void)handleRendererPid:(int)pid;
- (void)handleLoadEnd:(NSString*)url;
- (void)handleLoadError:(NSString*)url description:(NSString*)description;
- (void)handlePopup:(NSString*)url;
- (void)handleConsole:(NSString*)message level:(int)level;
- (void)handleTerminated:(NSString*)reason;
- (void)handleClosed;

@end

bool SroClient::OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                         CefRefPtr<CefFrame> frame,
                                         CefProcessId source_process,
                                         CefRefPtr<CefProcessMessage> message) {
  SroCefBrowser* owner = owner_;
  if (!owner) {
    return false;
  }
  const std::string name = message->GetName();
  CefRefPtr<CefListValue> arguments = message->GetArgumentList();
  if (name == sro::kPageToAppMessage) {
    [owner handlePageMessage:ToNSString(arguments->GetString(0))
                   mainFrame:frame->IsMain()
                         url:ToNSString(frame->GetURL())];
    return true;
  }
  if (name == sro::kEvaluateResultMessage) {
    [owner handleEvaluateResult:arguments->GetInt(0)
                             ok:arguments->GetBool(1)
                           text:ToNSString(arguments->GetString(2))];
    return true;
  }
  if (name == sro::kRendererInfoMessage) {
    [owner handleRendererPid:arguments->GetInt(0)];
    return true;
  }
  if (name == sro::kScriptErrorMessage) {
    [owner handleScriptError:[NSString stringWithFormat:@"%@: %@",
                                                        ToNSString(arguments->GetString(0)),
                                                        ToNSString(arguments->GetString(1))]];
    return true;
  }
  return false;
}

bool SroClient::OnBeforePopup(CefRefPtr<CefBrowser> browser,
                              CefRefPtr<CefFrame> frame,
                              int popup_id,
                              const CefString& target_url,
                              const CefString& target_frame_name,
                              WindowOpenDisposition target_disposition,
                              bool user_gesture,
                              const CefPopupFeatures& popupFeatures,
                              CefWindowInfo& windowInfo,
                              CefRefPtr<CefClient>& client,
                              CefBrowserSettings& settings,
                              CefRefPtr<CefDictionaryValue>& extra_info,
                              bool* no_javascript_access) {
  [owner_ handlePopup:ToNSString(target_url)];
  return true;
}

void SroClient::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  [owner_ attachBrowser:browser];
}

bool SroClient::DoClose(CefRefPtr<CefBrowser> browser) {
  return false;
}

void SroClient::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
  [owner_ handleClosed];
}

void SroClient::OnLoadEnd(CefRefPtr<CefBrowser> browser,
                          CefRefPtr<CefFrame> frame,
                          int httpStatusCode) {
  if (frame->IsMain()) {
    [owner_ handleLoadEnd:ToNSString(frame->GetURL())];
  }
}

void SroClient::OnLoadError(CefRefPtr<CefBrowser> browser,
                            CefRefPtr<CefFrame> frame,
                            ErrorCode errorCode,
                            const CefString& errorText,
                            const CefString& failedUrl) {
  if (frame->IsMain() && errorCode != ERR_ABORTED) {
    [owner_ handleLoadError:ToNSString(failedUrl) description:ToNSString(errorText)];
  }
}

bool SroClient::OnConsoleMessage(CefRefPtr<CefBrowser> browser,
                                 cef_log_severity_t level,
                                 const CefString& message,
                                 const CefString& source,
                                 int line) {
  [owner_ handleConsole:ToNSString(message) level:static_cast<int>(level)];
  return false;
}

void SroClient::OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                          TerminationStatus status,
                                          int error_code,
                                          const CefString& error_string) {
  [owner_ handleTerminated:[NSString stringWithFormat:@"status %d, code %d, %@", static_cast<int>(status),
                                                      error_code, ToNSString(error_string)]];
}

@implementation SroCefBrowser {
  CefRefPtr<CefBrowser> _browser;
  CefRefPtr<SroClient> _client;
  CefRefPtr<CefRegistration> _devToolsRegistration;
  NSMutableDictionary<NSNumber*, void (^)(NSData*)>* _screenshots;
  NSMutableDictionary<NSNumber*, void (^)(BOOL, NSString*)>* _pending;
  int _nextRequest;
  BOOL _allowEvaluate;
  BOOL _closed;
  BOOL _closeRequested;
  BOOL _audioMuted;
  int _rendererPid;
  NSUInteger _rejected;
}

- (instancetype)initWithParentView:(NSView*)parentView
                         cachePath:(NSString*)cachePath
                               url:(NSString*)url
                           scripts:(NSArray<NSString*>*)scripts
                     allowEvaluate:(BOOL)allowEvaluate
                          delegate:(id<SroCefBrowserDelegate>)delegate {
  self = [super init];
  if (!self) {
    return nil;
  }
  _delegate = delegate;
  _allowEvaluate = allowEvaluate;
  _pending = [NSMutableDictionary dictionary];
  _screenshots = [NSMutableDictionary dictionary];
  _client = new SroClient(self);

  CefRequestContextSettings context_settings;
  CefString(&context_settings.cache_path) = ToCefString(cachePath);
  context_settings.persist_session_cookies = true;
  CefRefPtr<CefRequestContext> context = CefRequestContext::CreateContext(context_settings, sro::CreatePackContextHandler());

  NSRect bounds = parentView.bounds;
  CefWindowInfo window_info;
  window_info.SetAsChild((__bridge void*)parentView,
                         CefRect(0, 0, static_cast<int>(bounds.size.width), static_cast<int>(bounds.size.height)));
  window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;

  CefBrowserSettings browser_settings;
  browser_settings.background_color = 0xFF000000;

  CefRefPtr<CefListValue> script_list = CefListValue::Create();
  for (NSUInteger index = 0; index < scripts.count; ++index) {
    script_list->SetString(index, ToCefString(scripts[index]));
  }
  CefRefPtr<CefDictionaryValue> extra_info = CefDictionaryValue::Create();
  extra_info->SetList(sro::kExtraInfoScripts, script_list);
  extra_info->SetBool(sro::kExtraInfoAllowEvaluate, allowEvaluate);

  if (!CefBrowserHost::CreateBrowser(window_info, _client, ToCefString(url), browser_settings, extra_info,
                                     context)) {
    return nil;
  }
  return self;
}

- (BOOL)isClosed {
  return _closed;
}

- (void)attachBrowser:(CefRefPtr<CefBrowser>)browser {
  _browser = browser;
  if (_audioMuted) {
    _browser->GetHost()->SetAudioMuted(true);
  }
  if (_allowEvaluate) {
    _devToolsRegistration = _browser->GetHost()->AddDevToolsMessageObserver(new SroDevToolsObserver(self));
  }
  if (_closeRequested) {
    _browser->GetHost()->CloseBrowser(true);
  }
}

- (int)identifier {
  return _browser ? _browser->GetIdentifier() : 0;
}

- (NSString*)currentUrl {
  if (!_browser) {
    return nil;
  }
  CefRefPtr<CefFrame> frame = _browser->GetMainFrame();
  return frame ? ToNSString(frame->GetURL()) : nil;
}

- (int)rendererProcessId {
  return _rendererPid;
}

- (void)handleRendererPid:(int)pid {
  _rendererPid = pid;
}

- (NSUInteger)rejectedMessageCount {
  return _rejected;
}

- (void)loadUrl:(NSString*)url {
  if (_browser && !_closed) {
    _browser->GetMainFrame()->LoadURL(ToCefString(url));
  }
}

- (void)reload {
  if (_browser && !_closed) {
    _browser->ReloadIgnoreCache();
  }
}

- (void)updateScripts:(NSArray<NSString*>*)scripts {
  if (!_browser || _closed) {
    return;
  }
  CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create(sro::kScriptsMessage);
  for (NSUInteger index = 0; index < scripts.count; ++index) {
    message->GetArgumentList()->SetString(index, ToCefString(scripts[index]));
  }
  _browser->GetMainFrame()->SendProcessMessage(PID_RENDERER, message);
}

- (void)sendMessageJson:(NSString*)json {
  if (!_browser || _closed) {
    return;
  }
  CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create(sro::kAppToPageMessage);
  message->GetArgumentList()->SetString(0, ToCefString(json));
  _browser->GetMainFrame()->SendProcessMessage(PID_RENDERER, message);
}

- (void)evaluate:(NSString*)code completion:(void (^)(BOOL, NSString*))completion {
  if (!_allowEvaluate || !_browser || _closed) {
    completion(NO, @"evaluation is not available");
    return;
  }
  int request = ++_nextRequest;
  _pending[@(request)] = [completion copy];
  CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create(sro::kEvaluateMessage);
  message->GetArgumentList()->SetInt(0, request);
  message->GetArgumentList()->SetString(1, ToCefString(code));
  _browser->GetMainFrame()->SendProcessMessage(PID_RENDERER, message);
}

- (void)captureScreenshot:(void (^)(NSData*))completion {
  if (!_allowEvaluate || !_browser || _closed) {
    completion(nil);
    return;
  }
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("format", "png");
  int identifier = _browser->GetHost()->ExecuteDevToolsMethod(0, "Page.captureScreenshot", params);
  if (identifier == 0) {
    completion(nil);
    return;
  }
  _screenshots[@(identifier)] = [completion copy];
}

- (void)handleDevToolsResult:(int)messageId success:(BOOL)success base64:(NSString*)base64 {
  void (^completion)(NSData*) = _screenshots[@(messageId)];
  if (!completion) {
    return;
  }
  [_screenshots removeObjectForKey:@(messageId)];
  completion(success ? [[NSData alloc] initWithBase64EncodedString:base64 options:0] : nil);
}

- (void)perform:(SroCefEditCommand)command {
  if (!_browser || _closed) {
    return;
  }
  CefRefPtr<CefFrame> frame = _browser->GetFocusedFrame();
  if (!frame) {
    frame = _browser->GetMainFrame();
  }
  switch (command) {
    case SroCefEditCommandUndo:
      frame->Undo();
      break;
    case SroCefEditCommandRedo:
      frame->Redo();
      break;
    case SroCefEditCommandCut:
      frame->Cut();
      break;
    case SroCefEditCommandCopy:
      frame->Copy();
      break;
    case SroCefEditCommandPaste:
      frame->Paste();
      break;
    case SroCefEditCommandSelectAll:
      frame->SelectAll();
      break;
  }
}

- (void)setAudioMuted:(BOOL)muted {
  _audioMuted = muted;
  if (_browser && !_closed) {
    _browser->GetHost()->SetAudioMuted(muted);
  }
}

- (BOOL)isAudioMuted {
  if (_browser && !_closed) {
    return _browser->GetHost()->IsAudioMuted();
  }
  return _audioMuted;
}

- (void)close {
  _closeRequested = YES;
  if (_browser && !_closed) {
    _browser->GetHost()->CloseBrowser(true);
  }
}

- (void)handlePageMessage:(NSString*)json mainFrame:(BOOL)mainFrame url:(NSString*)url {
  if (json.length > sro::kMaxPageMessageLength) {
    _rejected += 1;
    return;
  }
  [self.delegate cefBrowser:self didReceivePageMessage:json fromMainFrame:mainFrame pageUrl:url];
}

- (void)handleEvaluateResult:(int)request ok:(BOOL)ok text:(NSString*)text {
  void (^completion)(BOOL, NSString*) = _pending[@(request)];
  [_pending removeObjectForKey:@(request)];
  if (completion) {
    completion(ok, text);
  }
}

- (void)handleScriptError:(NSString*)description {
  [self.delegate cefBrowser:self didReportScriptError:description];
}

- (void)handleLoadEnd:(NSString*)url {
  [self.delegate cefBrowser:self didFinishLoadingUrl:url];
}

- (void)handleLoadError:(NSString*)url description:(NSString*)description {
  [self.delegate cefBrowser:self didFailLoadingUrl:url description:description];
}

- (void)handlePopup:(NSString*)url {
  [self.delegate cefBrowser:self wantsToOpenPopupToUrl:url];
}

- (void)handleConsole:(NSString*)message level:(int)level {
  [self.delegate cefBrowser:self didLogConsoleMessage:message level:level];
}

- (void)handleTerminated:(NSString*)reason {
  [self.delegate cefBrowser:self rendererDidTerminate:reason];
}

- (void)handleClosed {
  _closed = YES;
  _browser = nullptr;
  for (NSNumber* key in _pending.allKeys) {
    _pending[key](NO, @"the browser closed");
  }
  for (NSNumber* key in _screenshots.allKeys) {
    _screenshots[key](nil);
  }
  [_screenshots removeAllObjects];
  _devToolsRegistration = nullptr;
  [_pending removeAllObjects];
  [self.delegate cefBrowserDidClose:self];
}

@end
