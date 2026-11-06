#!/bin/sh
set -e
cd "$(dirname "$0")/../.."
cat macos/cef/cef-version.env macos/scripts/cef-fetch-remote.sh | ssh "${SRO_SSH_HOST:-mac}" 'sh -s'
