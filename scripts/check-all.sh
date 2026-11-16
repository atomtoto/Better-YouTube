#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
portable=false
case "${1:-}" in
    --portable) portable=true ;;
    "") ;;
    *) echo "Usage: scripts/check-all.sh [--portable]" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
    echo "Usage: scripts/check-all.sh [--portable]" >&2
    exit 2
fi
if ! "$portable" && [ "$(uname -s)" != Darwin ]; then
    echo "Full checks require macOS and Xcode. Use --portable on other platforms." >&2
    exit 2
fi

node --test scripts/test-youtube-links-extension.cjs
python3 resolver/test_server.py
if ! "$portable"; then
    # The download fixtures listen on loopback inside the sandboxed test host.
    xcodebuild test -project BetterYouTube/BetterYouTube.xcodeproj \
        -scheme BetterYouTube -destination 'platform=macOS' \
        ENABLE_INCOMING_NETWORK_CONNECTIONS=YES
    python3 scripts/check-localizations.py
fi
