#pragma once

#import "SroCefBridge.h"

#include <string>

#include "include/cef_request.h"
#include "include/cef_request_context_handler.h"
#include "include/cef_resource_request_handler.h"

namespace sro {

void SetPackProvider(id<SroCefPackProvider> provider);

CefRefPtr<CefResourceRequestHandler> CreatePackRequestHandler(
    CefRefPtr<CefRequest> request,
    const std::string& source);

CefRefPtr<CefRequestContextHandler> CreatePackContextHandler();

}
