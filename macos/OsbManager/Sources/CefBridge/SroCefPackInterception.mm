#import "SroCefPackInterception.h"

#include <algorithm>
#include <cstring>
#include <memory>
#include <mutex>

#include "include/cef_callback.h"
#include "include/cef_resource_handler.h"
#include "include/cef_response.h"

namespace sro {

namespace {

std::mutex g_provider_mutex;
id<SroCefPackProvider> g_provider = nil;

id<SroCefPackProvider> CurrentProvider() {
  std::lock_guard<std::mutex> lock(g_provider_mutex);
  return g_provider;
}

NSString* ToNSString(const CefString& value) {
  return [NSString stringWithUTF8String:value.ToString().c_str()];
}

class PackResourceHandler : public CefResourceHandler {
 public:
  PackResourceHandler(NSData* body, NSDictionary<NSString*, NSString*>* headers)
      : body_(body), headers_(headers) {}

  bool Open(CefRefPtr<CefRequest> request,
            bool& handle_request,
            CefRefPtr<CefCallback> callback) override {
    handle_request = true;
    return true;
  }

  void GetResponseHeaders(CefRefPtr<CefResponse> response,
                          int64_t& response_length,
                          CefString& redirectUrl) override {
    response->SetStatus(206);
    response->SetStatusText("Partial Content");
    NSString* type = headers_[@"Content-Type"];
    response->SetMimeType(type ? type.UTF8String : "application/octet-stream");
    [headers_ enumerateKeysAndObjectsUsingBlock:^(NSString* name, NSString* value, BOOL* stop) {
      if (![name isEqualToString:@"Content-Type"] && ![name isEqualToString:@"Content-Length"]) {
        response->SetHeaderByName(name.UTF8String, value.UTF8String, true);
      }
    }];
    response_length = static_cast<int64_t>(body_.length);
  }

  bool Skip(int64_t bytes_to_skip,
            int64_t& bytes_skipped,
            CefRefPtr<CefResourceSkipCallback> callback) override {
    bytes_skipped = std::max<int64_t>(bytes_to_skip, 0);
    return true;
  }

  bool Read(void* data_out,
            int bytes_to_read,
            int& bytes_read,
            CefRefPtr<CefResourceReadCallback> callback) override {
    const int64_t remaining = static_cast<int64_t>(body_.length) - offset_;
    if (remaining <= 0) {
      bytes_read = 0;
      return false;
    }
    const int count = static_cast<int>(std::min<int64_t>(bytes_to_read, remaining));
    std::memcpy(data_out, static_cast<const uint8_t*>(body_.bytes) + offset_, count);
    offset_ += count;
    bytes_read = count;
    return true;
  }

  void Cancel() override {}

 private:
  NSData* body_;
  NSDictionary<NSString*, NSString*>* headers_;
  int64_t offset_ = 0;

  IMPLEMENT_REFCOUNTING(PackResourceHandler);
};

struct Handoff {
  std::mutex mutex;
  bool returned = false;
  bool done = false;
};

class PackRequestHandler : public CefResourceRequestHandler {
 public:
  explicit PackRequestHandler(const std::string& source) : source_(source) {}

  ReturnValue OnBeforeResourceLoad(CefRefPtr<CefBrowser> browser,
                                   CefRefPtr<CefFrame> frame,
                                   CefRefPtr<CefRequest> request,
                                   CefRefPtr<CefCallback> callback) override {
    id<SroCefPackProvider> provider = CurrentProvider();
    if (!provider) {
      return RV_CONTINUE;
    }
    auto handoff = std::make_shared<Handoff>();
    CefRefPtr<PackRequestHandler> keep(this);
    [provider serveUrl:ToNSString(request->GetURL())
           rangeHeader:ToNSString(request->GetHeaderByName("Range"))
                source:[NSString stringWithUTF8String:source_.c_str()]
            completion:^(NSData* body, NSDictionary<NSString*, NSString*>* headers) {
              if (body && headers) {
                keep->body_ = body;
                keep->headers_ = headers;
              }
              bool resume = false;
              {
                std::lock_guard<std::mutex> lock(handoff->mutex);
                handoff->done = true;
                resume = handoff->returned;
              }
              if (resume) {
                callback->Continue();
              }
            }];
    std::lock_guard<std::mutex> lock(handoff->mutex);
    if (handoff->done) {
      return RV_CONTINUE;
    }
    handoff->returned = true;
    return RV_CONTINUE_ASYNC;
  }

  CefRefPtr<CefResourceHandler> GetResourceHandler(CefRefPtr<CefBrowser> browser,
                                                   CefRefPtr<CefFrame> frame,
                                                   CefRefPtr<CefRequest> request) override {
    if (!body_ || !headers_) {
      return nullptr;
    }
    return new PackResourceHandler(body_, headers_);
  }

 private:
  std::string source_;
  NSData* body_ = nil;
  NSDictionary<NSString*, NSString*>* headers_ = nil;

  IMPLEMENT_REFCOUNTING(PackRequestHandler);
};

class PackContextHandler : public CefRequestContextHandler {
 public:
  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request,
      bool is_navigation,
      bool is_download,
      const CefString& request_initiator,
      bool& disable_default_handling) override {
    return CreatePackRequestHandler(request, "context");
  }

 private:
  IMPLEMENT_REFCOUNTING(PackContextHandler);
};

}

void SetPackProvider(id<SroCefPackProvider> provider) {
  std::lock_guard<std::mutex> lock(g_provider_mutex);
  g_provider = provider;
}

CefRefPtr<CefResourceRequestHandler> CreatePackRequestHandler(
    CefRefPtr<CefRequest> request,
    const std::string& source) {
  id<SroCefPackProvider> provider = CurrentProvider();
  if (!provider) {
    return nullptr;
  }
  NSString* range = request->GetHeaderByName("Range").empty()
                        ? nil
                        : ToNSString(request->GetHeaderByName("Range"));
  if (![provider wantsMethod:ToNSString(request->GetMethod())
                         url:ToNSString(request->GetURL())
                 rangeHeader:range]) {
    return nullptr;
  }
  return new PackRequestHandler(source);
}

CefRefPtr<CefRequestContextHandler> CreatePackContextHandler() {
  return new PackContextHandler();
}

}
