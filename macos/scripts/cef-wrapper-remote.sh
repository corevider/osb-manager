#!/bin/sh
set -e
cef="${CEF_ROOT:-$HOME/sro/cef/${CEF_FILE%.tar.bz2}}"
out="${CEF_WRAPPER_DIR:-$cef/wrapper-build}"
jobs="${JOBS:-6}"
stamp="$out/.built"
if [ -f "$stamp" ] && [ -f "$out/libcef_dll_wrapper.a" ]; then
    echo "The wrapper is already built in $out"
    exit 0
fi
rm -rf "$out"
mkdir -p "$out/obj"
cd "$cef"

flags="-std=c++20 -O2 -fPIC -fno-exceptions -fno-rtti -fno-strict-aliasing -fno-threadsafe-statics -fobjc-call-cxx-cdtors -fvisibility=hidden -fvisibility-inlines-hidden -fstack-protector -funwind-tables -mmacosx-version-min=13.0 -arch arm64 -I$cef -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -DWRAPPING_CEF_SHARED -Wno-deprecated-declarations -Wno-narrowing"

find libcef_dll -name '*.cc' -o -name '*.mm' | grep -v '_win\.cc$\|_linux\.cc$' | sort > "$out/sources.txt"

cat > "$out/compile-one.sh" <<SCRIPT
#!/bin/sh
source="\$1"
object="$out/obj/\$(printf '%s' "\$source" | tr '/' '_').o"
case "\$source" in
    *.mm) exec clang++ $flags -x objective-c++ -c "\$source" -o "\$object" ;;
    *) exec clang++ $flags -c "\$source" -o "\$object" ;;
esac
SCRIPT

count=$(wc -l < "$out/sources.txt" | tr -d ' ')
echo "Compiling $count wrapper sources with $jobs jobs"
xargs -n 1 -P "$jobs" sh "$out/compile-one.sh" < "$out/sources.txt"

ar rcs "$out/libcef_dll_wrapper.a" "$out"/obj/*.o
rm -rf "$out/obj"
touch "$stamp"
echo "Built $out/libcef_dll_wrapper.a ($(du -h "$out/libcef_dll_wrapper.a" | cut -f1))"
