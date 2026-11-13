#!/bin/sh
set -e
base="${SRO_BASE:?SRO_BASE must name the build folder}"
variant="${VARIANT:-app}"
. "$base/macos/cef/cef-version.env"
cef="${CEF_ROOT:-$HOME/sro/cef/${CEF_FILE%.tar.bz2}}"
wrapper="${CEF_WRAPPER_DIR:-$cef/wrapper-build}"
package="$base/macos/OsbManager"
scratch="${SCRATCH:-$base/build}"
shared="$base/src/OsbManager/Browser"
output_folder="${OUT_DIR:-$base}"
version="${VERSION:-$(cat "$package/VERSION" 2>/dev/null || echo 0.0.0)}"
build="${BUILD_NUMBER:-1}"
configuration="${CONFIGURATION:-release}"
app_identifier="com.corevider.osb-manager"
app_name="OSB Manager"

if [ ! -f "$wrapper/libcef_dll_wrapper.a" ] || [ ! -d "$cef/Release/Chromium Embedded Framework.framework" ]; then
    echo "CEF is not fetched or its wrapper is not built. Run macos/scripts/cef-fetch.sh and macos/scripts/cef-wrapper.sh first." >&2
    exit 1
fi

app_entitlements="${APP_ENTITLEMENTS:-$package/App.entitlements}"
helper_entitlements="${HELPER_ENTITLEMENTS:-$package/Helper.entitlements}"
basic_helper_entitlements="${BASIC_HELPER_ENTITLEMENTS:-$package/HelperBasic.entitlements}"

adhoc_entitlements() {
    merged="$scratch/adhoc-$(basename "$1")"
    cp "$1" "$merged"
    /usr/libexec/PlistBuddy -c "Delete :com.apple.security.cs.disable-library-validation" "$merged" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$merged" >/dev/null
    echo "$merged"
}

sign() {
    target="$1"
    entitlements="$2"
    set -- --force
    if [ -n "$SIGN_IDENTITY" ]; then
        set -- "$@" --options runtime --timestamp --sign "$SIGN_IDENTITY"
    elif [ "${HARDENED_RUNTIME:-0}" = 1 ]; then
        set -- "$@" --options runtime --timestamp=none --sign -
        [ -n "$entitlements" ] && entitlements="$(adhoc_entitlements "$entitlements")"
    else
        set -- "$@" --sign -
    fi
    if [ -n "$entitlements" ]; then
        set -- "$@" --entitlements "$entitlements"
    fi
    codesign "$@" "$target"
}

export CEF_ROOT="$cef" CEF_WRAPPER_DIR="$wrapper"
cd "$package"
case "$variant" in
    app) products="OsbManager" ;;
    e2e) products="OsbManagerE2E" ;;
    both) products="OsbManager OsbManagerE2E" ;;
    *)
        echo "unknown VARIANT $variant" >&2
        exit 2
        ;;
esac
mkdir -p "$scratch"
for product in $products; do
    if ! swift build -c "$configuration" --arch arm64 --product "$product" --scratch-path "$scratch" > "$scratch/swift-build.log" 2>&1; then
        grep -E "error" "$scratch/swift-build.log" | cut -c1-300 | sort -u | head -40
        echo "swift build failed for $product" >&2
        exit 1
    fi
    grep -E "warning:|Build complete" "$scratch/swift-build.log" | cut -c1-300 | sort -u
done
bin="$(swift build -c "$configuration" --arch arm64 --scratch-path "$scratch" --show-bin-path)"
for product in $products; do
    sh "$base/macos/scripts/check-frame-symbols.sh" "$bin/$product"
done

helper_binary="$scratch/helper"
mkdir -p "$scratch"
clang++ -std=c++20 -O2 -arch arm64 -mmacosx-version-min=13.0 \
    -fno-rtti -fno-exceptions -fno-strict-aliasing -fvisibility=hidden -fvisibility-inlines-hidden \
    -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -Wno-deprecated-declarations \
    -I "$cef" -I "$package/Sources/CefBridge" \
    "$package/Helper/helper_main.cc" "$package/Sources/CefBridge/SroCefApp.cc" \
    -L "$wrapper" -lcef_dll_wrapper -framework Cocoa -framework IOSurface -Wl,-dead_strip \
    -o "$helper_binary"

icon="$scratch/icon"
icon_master="${ICON_MASTER:-$base/docs/macos/app-icon-1024.png}"
if [ ! -f "$icon_master" ]; then
    echo "The icon master $icon_master is missing. Copy docs/macos/app-icon-1024.png with the sources." >&2
    exit 1
fi
rm -rf "$icon"
mkdir -p "$icon/AppIcon.iconset"
for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x 128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 512:icon_256x256@2x 512:icon_512x512 1024:icon_512x512@2x; do
    sips -s format png -z "${spec%%:*}" "${spec%%:*}" "$icon_master" --out "$icon/AppIcon.iconset/${spec#*:}.png" >/dev/null
done
iconutil -c icns "$icon/AppIcon.iconset" -o "$icon/AppIcon.icns"

assemble() {
    product="$1"
    name="$2"
    identifier="$3"
    output="$output_folder/$name.app"
    contents="$output/Contents"
    rm -rf "$output"
    mkdir -p "$contents/MacOS" "$contents/Resources" "$contents/Frameworks"
    cp "$bin/$product" "$contents/MacOS/$name"
    sed -e "s/__NAME__/$name/g" -e "s/__IDENTIFIER__/$identifier/g" -e "s/__VERSION__/$version/g" -e "s/__BUILD__/$build/g" "$package/Info.plist.in" > "$contents/Info.plist"
    plutil -lint "$contents/Info.plist" >/dev/null
    for script in autologin light gpu drops bridge; do
        cp "$shared/$script.js" "$contents/Resources/$script.js"
    done
    cp "$package/Resources/cef-shim.js" "$contents/Resources/"
    cp "$package/Resources/diagnostics-vocabulary.json" "$contents/Resources/"
    cp "$icon/AppIcon.icns" "$contents/Resources/AppIcon.icns"

    ditto "$cef/Release/Chromium Embedded Framework.framework" "$contents/Frameworks/Chromium Embedded Framework.framework"
    for helper_variant in "" " (Alerts)" " (GPU)" " (Plugin)" " (Renderer)"; do
        helper="$name Helper$helper_variant"
        suffix="$(printf '%s' "$helper_variant" | tr 'A-Z' 'a-z' | tr -d ' ()')"
        helper_identifier="$identifier.helper"
        [ -n "$suffix" ] && helper_identifier="$identifier.helper.$suffix"
        helper_app="$contents/Frameworks/$helper.app"
        mkdir -p "$helper_app/Contents/MacOS"
        cp "$helper_binary" "$helper_app/Contents/MacOS/$helper"
        sed -e "s/__NAME__/$helper/g" -e "s/__IDENTIFIER__/$helper_identifier/g" -e "s/__VERSION__/$version/g" -e "s/__BUILD__/$build/g" "$package/helper-Info.plist.in" > "$helper_app/Contents/Info.plist"
        plutil -lint "$helper_app/Contents/Info.plist" >/dev/null
    done

    framework="$contents/Frameworks/Chromium Embedded Framework.framework"
    for library in "$framework"/Libraries/*.dylib; do
        sign "$library"
    done
    sign "$framework"
    for helper_app in "$contents"/Frameworks/*Helper*.app; do
        case "$helper_app" in
            *" Helper.app" | *"(Renderer).app") sign "$helper_app" "$helper_entitlements" ;;
            *) sign "$helper_app" "$basic_helper_entitlements" ;;
        esac
    done
    sign "$output" "$app_entitlements"
    codesign --verify --deep --strict "$output"
    echo "built $output"
    du -sh "$output"
}

case "$variant" in
    app) assemble OsbManager "$app_name" "$app_identifier" ;;
    e2e) assemble OsbManagerE2E "$app_name E2E" "$app_identifier.e2e" ;;
    both)
        assemble OsbManager "$app_name" "$app_identifier"
        assemble OsbManagerE2E "$app_name E2E" "$app_identifier.e2e"
        ;;
esac
