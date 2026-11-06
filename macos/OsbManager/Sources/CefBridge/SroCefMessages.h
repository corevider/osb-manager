#pragma once

#include <cstddef>

namespace sro {

constexpr char kPageToAppMessage[] = "sro.post";
constexpr char kAppToPageMessage[] = "sro.dispatch";
constexpr char kScriptsMessage[] = "sro.scripts";
constexpr char kEvaluateMessage[] = "sro.evaluate";
constexpr char kEvaluateResultMessage[] = "sro.evaluate-result";
constexpr char kScriptErrorMessage[] = "sro.script-error";
constexpr char kRendererInfoMessage[] = "sro.renderer-info";

constexpr char kExtraInfoScripts[] = "scripts";
constexpr char kExtraInfoAllowEvaluate[] = "allowEvaluate";

constexpr char kGameOrigin[] = "https://opensro.online";
constexpr size_t kMaxPageMessageLength = 16 * 1024;

}
