#!/bin/bash
# FnClearup CGI Entry Point
# Pure Bash CGI - Version 0.2.4

DEBUG_LOG="/tmp/fnclearup_debug.log"
API_SH="$(dirname "$0")/app/api.sh"

# Log invocation
echo "=== index.cgi invoked ===" >> "$DEBUG_LOG"
echo "PATH_INFO=$PATH_INFO" >> "$DEBUG_LOG"
echo "REQUEST_METHOD=$REQUEST_METHOD" >> "$DEBUG_LOG"
echo "REQUEST_URI=$REQUEST_URI" >> "$DEBUG_LOG"
echo "SCRIPT_NAME=$SCRIPT_NAME" >> "$DEBUG_LOG"

# If PATH_INFO starts with /api/, delegate to api.sh
if [[ "$PATH_INFO" == /api/* ]]; then
    # Remove /api prefix - api.sh expects paths like /version, /scan, /delete
    export PATH_INFO="${PATH_INFO#/api}"
    exec "$API_SH"
fi

# Otherwise serve static HTML
echo "Content-Type: text/html"
echo ""
exec "$(dirname "$0")/app/ui/www/index.html"
