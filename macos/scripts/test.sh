#!/bin/sh
set -e
cd "$(dirname "$0")/../.."
base="${SRO_BASE:-sro/t008}"
ssh "${SRO_SSH_HOST:-mac}" ". ~/$base/macos/cef/cef-version.env; cd ~/$base/macos/OsbManager && CEF_ROOT=\$HOME/sro/cef/\${CEF_FILE%.tar.bz2} SRO_REAL_KEYCHAIN=${REAL_KEYCHAIN:-0} swift test --arch arm64 --scratch-path ~/$base/build-test $TEST_ARGS 2>&1" | tee "${TEST_LOG:-/dev/null}" | grep -vE "^\[[0-9]+/[0-9]+\]|^Compiling|^Building" | cut -c1-300
