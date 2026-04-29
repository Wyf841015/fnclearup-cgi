#!/bin/bash
#
# FnClearup CGI Entry Point v0.3.1
# Pure Bash CGI - No Python
#
# URL routing:
#   /index.cgi/           → index.html
#   /index.cgi/api/scan   → api.sh /scan
#   /index.cgi/api/delete → api.sh /delete
#   /index.cgi/api/ping   → api.sh /ping
#   /index.cgi/static/*   → static files from www/
#

set -euo pipefail

DEBUG_LOG="/tmp/fnclearup_debug.log"

BASE_DIR="/var/apps/App.Native.FnClearup/target"
API_SH="$BASE_DIR/api.sh"
WWW_DIR="$BASE_DIR/ui/www"

{
    echo "=== index.cgi invoked ==="
    echo "SCRIPT_FILENAME=${SCRIPT_FILENAME:-UNSET}"
    echo "REQUEST_URI=${REQUEST_URI:-UNSET}"
    echo "PATH_INFO=${PATH_INFO:-UNSET}"
} >> "$DEBUG_LOG"

# Strip query string, then extract path after index.cgi
URI_NO_QUERY="${REQUEST_URI%%\?*}"
REL_PATH="${URI_NO_QUERY#*index.cgi}"
REL_PATH="${REL_PATH#/}"

# ── API proxy ───────────────────────────────────────────────────────────────
if [[ "$REL_PATH" == api/* ]]; then
    API_ENDPOINT="/${REL_PATH#api/}"

    {
        echo "=== proxying: REL_PATH=$REL_PATH → API_ENDPOINT=$API_ENDPOINT"
        echo "REQUEST_METHOD=$REQUEST_METHOD"
    } >> "$DEBUG_LOG"

    # Read request body
    if [[ -n "${CONTENT_LENGTH:-}" ]] && [[ "${CONTENT_LENGTH}" -gt 0 ]] 2>/dev/null; then
        BODY_TMP=$(mktemp)
        dd bs=1 count="${CONTENT_LENGTH}" of="$BODY_TMP" 2>/dev/null || >"$BODY_TMP"
    else
        BODY_TMP=$(mktemp)
        : >"$BODY_TMP"
    fi

    export PATH_INFO="$API_ENDPOINT"
    export REQUEST_METHOD="${REQUEST_METHOD:-GET}"
    export REQUEST_URI="$REQUEST_URI"

    RESPONSE=$(bash "$API_SH" < "$BODY_TMP" 2>>"$DEBUG_LOG")
    rm -f "$BODY_TMP"

    {
        echo "api.sh response length=${#RESPONSE}"
        echo "api.sh response first 200 chars: ${RESPONSE:0:200}"
    } >> "$DEBUG_LOG"

    # Parse CRLF-delimited HTTP response from api.sh
    # Response format:
    #   Status: 200 OK\r\n
    #   Content-Type: application/json\r\n
    #   \r\n
    #   {json_body}

    # Get status line
    STATUS_CODE=$(printf '%s\r\n' "$RESPONSE" | sed -n '1s/Status: //p' | tr -d '\r\n')

    # Find body start: first \r\n\r\n in the raw response
    BODY=$(printf '%s' "$RESPONSE" | awk '
        BEGIN { found_blank=0 }
        {
            if (found_blank) { body = body $0 "\n" }
            else {
                line = $0
                gsub(/\r/, "", line)
                if (line == "") { found_blank=1 }
            }
        }
        END { printf "%s", body }
    ')
    # Remove trailing newline
    BODY=$(printf '%s' "$BODY" | sed 's/\n$//')

    CONTENT_TYPE="application/json"
    [[ -z "$STATUS_CODE" ]] && STATUS_CODE="200"

    printf 'Status: %s\r\n' "${STATUS_CODE}"
    printf 'Content-Type: %s\r\n' "$CONTENT_TYPE"
    printf '\r\n'
    printf '%s' "$BODY"
    exit 0
fi

# ── Static files ─────────────────────────────────────────────────────────────
if [[ -z "$REL_PATH" || "$REL_PATH" == "/" ]]; then
    REL_PATH="index.html"
fi

TARGET_FILE="$WWW_DIR/$REL_PATH"

# Security: prevent path traversal
if [[ "$TARGET_FILE" == *..* ]]; then
    printf 'Status: 400\r\n'
    printf 'Content-Type: text/plain\r\n'
    printf '\r\n'
    printf 'Bad Request'
    exit 0
fi

if [[ ! -f "$TARGET_FILE" ]]; then
    printf 'Status: 404\r\n'
    printf 'Content-Type: text/plain\r\n'
    printf '\r\n'
    printf '404 Not Found'
    exit 0
fi

# Determine MIME type
ext="${TARGET_FILE##*.}"
ext_lc="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
case "$ext_lc" in
    html|htm) mime="text/html; charset=utf-8" ;;
    css)      mime="text/css; charset=utf-8" ;;
    js)       mime="application/javascript; charset=utf-8" ;;
    json)     mime="application/json; charset=utf-8" ;;
    png)      mime="image/png" ;;
    jpg|jpeg) mime="image/jpeg" ;;
    gif)      mime="image/gif" ;;
    svg)      mime="image/svg+xml" ;;
    ico)      mime="image/x-icon" ;;
    txt|log)  mime="text/plain; charset=utf-8" ;;
    *)        mime="application/octet-stream" ;;
esac

size=$(wc -c < "$TARGET_FILE")
last_mod=$(date -u -r "$TARGET_FILE" +"%a, %d %b %Y %H:%M:%S GMT" 2>/dev/null || echo "")

printf 'Content-Type: %s\r\n' "$mime"
printf 'Content-Length: %s\r\n' "$size"
[[ -n "$last_mod" ]] && printf 'Last-Modified: %s\r\n' "$last_mod"
printf '\r\n'

if [[ "${REQUEST_METHOD:-GET}" != "HEAD" ]]; then
    cat "$TARGET_FILE"
fi
