#!/bin/bash
#
# FnClearup CGI Entry Point v0.2.7-fixed
# Hardcoded paths: /var/apps/App.Native.FnClearup/target/
#

set -euo pipefail

DEBUG_LOG="/tmp/fnclearup_debug.log"

# ── Hardcoded base (FnOS installs to this path) ────────────────────────────
BASE_DIR="/var/apps/App.Native.FnClearup/target"
API_SH="$BASE_DIR/api.sh"
WWW_DIR="$BASE_DIR/ui/www"

# ── Debug ─────────────────────────────────────────────────────────────────
echo "=== index.cgi invoked ===" >> "$DEBUG_LOG"
echo "SCRIPT_FILENAME=${SCRIPT_FILENAME:-UNSET}" >> "$DEBUG_LOG"
echo "REQUEST_URI=${REQUEST_URI:-UNSET}" >> "$DEBUG_LOG"
echo "BASE_DIR=$BASE_DIR" >> "$DEBUG_LOG"
echo "WWW_DIR=$WWW_DIR" >> "$DEBUG_LOG"

# ── Extract path after index.cgi ─────────────────────────────────────────
URI_NO_QUERY="${REQUEST_URI%%\?*}"
REL_PATH="${URI_NO_QUERY#*index.cgi}"
REL_PATH="${REL_PATH#/}"

# ── API proxy ──────────────────────────────────────────────────────────────
if [[ "$REL_PATH" == api/* ]]; then
    API_PATH="/${REL_PATH#api/}"

    echo "=== proxying to api.sh PATH_INFO=$API_PATH ===" >> "$DEBUG_LOG"

    # Collect body
    if [[ -n "${CONTENT_LENGTH:-}" ]] && [[ "${CONTENT_LENGTH}" -gt 0 ]] 2>/dev/null; then
        BODY_TMP=$(mktemp)
        dd bs=1 count="${CONTENT_LENGTH}" of="$BODY_TMP" 2>/dev/null || cat >"$BODY_TMP"
    else
        BODY_TMP=$(mktemp)
        : >"$BODY_TMP"
    fi

    export PATH_INFO="$API_PATH"
    export REQUEST_METHOD="${REQUEST_METHOD:-GET}"

    RESPONSE=$(bash "$API_SH" < "$BODY_TMP" 2>>"$DEBUG_LOG")

    # Parse api.sh response
    STATUS_LINE=$(echo "$RESPONSE" | head -n 1)
    BODY=$(echo "$RESPONSE" | sed '1,/^\n*$/d')
    STATUS_CODE="${STATUS_LINE#Status: }"
    STATUS_CODE="${STATUS_CODE%$'\r'*}"
    CONTENT_TYPE=$(echo "$RESPONSE" | grep -i '^Content-Type:' | sed 's/^[Cc]ontent-[Tt]ype:[[:space:]]*//' | tr -d '\r' | head -n1)
    [[ -z "$CONTENT_TYPE" ]] && CONTENT_TYPE="application/json"

    printf 'Status: %s\r\n' "${STATUS_CODE:-200}"
    printf 'Content-Type: %s\r\n' "$CONTENT_TYPE"
    printf '\r\n'
    printf '%s' "$BODY"

    rm -f "$BODY_TMP"
    exit 0
fi

# ── Static files ───────────────────────────────────────────────────────────
if [[ -z "$REL_PATH" || "$REL_PATH" == "/" ]]; then
    REL_PATH="index.html"
fi

TARGET_FILE="$WWW_DIR/$REL_PATH"
echo "TARGET_FILE=$TARGET_FILE" >> "$DEBUG_LOG"

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
    printf '404 Not Found: %s' "$REL_PATH"
    exit 0
fi

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
