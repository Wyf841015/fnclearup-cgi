#!/bin/bash
# FnClearup CGI Entry Point
# Pure Bash CGI - Version 0.2.6

DEBUG_LOG="/tmp/fnclearup_debug.log"
APP_DIR="$(dirname "$(dirname "$0")")"
API_SH="$APP_DIR/app/api.sh"

# Log invocation
echo "=== index.cgi invoked ===" >> "$DEBUG_LOG"
echo "PATH_INFO=$PATH_INFO" >> "$DEBUG_LOG"
echo "REQUEST_METHOD=$REQUEST_METHOD" >> "$DEBUG_LOG"

# PATH_INFO from FnOS looks like:
#   /cgi/ThirdParty/App.Native.FnClearup/index.cgi/api/scan
# We need to extract the part AFTER index.cgi, e.g. /api/scan
FULL_PATH="${PATH_INFO:-/}"

# Strip everything up to and including index.cgi
API_PATH="${FULL_PATH#*index.cgi}"
API_PATH="${API_PATH#/}"   # remove leading / if any

if [[ "$API_PATH" == api/* ]]; then
    API_PATH="/${API_PATH#/api}"  # normalize to /version, /scan etc
    export PATH_INFO="$API_PATH"
    echo "=== delegating to api.sh PATH_INFO=$PATH_INFO ===" >> "$DEBUG_LOG"
    exec "$API_SH"
fi

# Otherwise serve static HTML
echo "Content-Type: text/html"
echo ""
exec "$APP_DIR/app/ui/www/index.html"
