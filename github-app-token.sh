#!/bin/bash
# github-app-token.sh — Generate and cache GitHub App installation tokens
#
# Usage:
#   github-app-token.sh get      # returns a valid token (cached or fresh)
#   github-app-token.sh refresh   # force-generates a new token
#
# Required environment variables:
#   GITHUB_APP_ID                    — Numeric App ID
#   GITHUB_APP_PRIVATE_KEY_BASE64    — Base64-encoded PEM private key
#   GITHUB_APP_INSTALLATION_ID       — Numeric installation ID for the org

set -euo pipefail

CACHE_FILE="/tmp/github-app-token-cache.json"
# Refresh when within 5 minutes of expiry
EXPIRY_BUFFER_SECONDS=300

die() { echo "github-app-token: $*" >&2; exit 1; }

# ---------- JWT generation (RS256) ----------
generate_jwt() {
    local app_id="$GITHUB_APP_ID"
    local now
    now=$(date +%s)
    local iat=$((now - 60))     # issued 60 s in the past to allow clock skew
    local exp=$((now + 600))    # 10-minute lifetime (GitHub maximum)

    # Header
    local header
    header=$(printf '{"alg":"RS256","typ":"JWT"}' | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')

    # Payload
    local payload
    payload=$(printf '{"iss":"%s","iat":%d,"exp":%d}' "$app_id" "$iat" "$exp" \
        | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')

    # Signature
    local pem
    pem=$(echo "$GITHUB_APP_PRIVATE_KEY_BASE64" | base64 -d)

    local signature
    signature=$(printf '%s.%s' "$header" "$payload" \
        | openssl dgst -sha256 -sign <(echo "$pem") \
        | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')

    printf '%s.%s.%s' "$header" "$payload" "$signature"
}

# ---------- Token exchange ----------
request_installation_token() {
    local jwt
    jwt=$(generate_jwt)

    local response
    response=$(curl -sf -X POST \
        -H "Authorization: Bearer ${jwt}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/app/installations/${GITHUB_APP_INSTALLATION_ID}/access_tokens")

    local token expires_at
    token=$(echo "$response" | jq -r '.token // empty')
    expires_at=$(echo "$response" | jq -r '.expires_at // empty')

    if [ -z "$token" ]; then
        die "failed to obtain installation token"
    fi

    # Write cache
    jq -n --arg t "$token" --arg e "$expires_at" \
        '{"token":$t,"expires_at":$e}' > "$CACHE_FILE"

    echo "$token"
}

# ---------- Cache logic ----------
get_cached_token() {
    if [ ! -f "$CACHE_FILE" ]; then
        return 1
    fi

    local token expires_at expires_epoch now
    token=$(jq -r '.token // empty' "$CACHE_FILE" 2>/dev/null) || return 1
    expires_at=$(jq -r '.expires_at // empty' "$CACHE_FILE" 2>/dev/null) || return 1

    if [ -z "$token" ] || [ -z "$expires_at" ]; then
        return 1
    fi

    # Parse ISO 8601 expiry to epoch
    expires_epoch=$(date -d "$expires_at" +%s 2>/dev/null) || return 1
    now=$(date +%s)

    if [ $((expires_epoch - now)) -le $EXPIRY_BUFFER_SECONDS ]; then
        return 1  # too close to expiry
    fi

    echo "$token"
}

# ---------- Main ----------
case "${1:-}" in
    get)
        # Validate required env vars
        [ -n "${GITHUB_APP_ID:-}" ]                 || die "GITHUB_APP_ID not set"
        [ -n "${GITHUB_APP_PRIVATE_KEY_BASE64:-}" ] || die "GITHUB_APP_PRIVATE_KEY_BASE64 not set"
        [ -n "${GITHUB_APP_INSTALLATION_ID:-}" ]    || die "GITHUB_APP_INSTALLATION_ID not set"

        if token=$(get_cached_token); then
            echo "$token"
        else
            request_installation_token
        fi
        ;;
    refresh)
        [ -n "${GITHUB_APP_ID:-}" ]                 || die "GITHUB_APP_ID not set"
        [ -n "${GITHUB_APP_PRIVATE_KEY_BASE64:-}" ] || die "GITHUB_APP_PRIVATE_KEY_BASE64 not set"
        [ -n "${GITHUB_APP_INSTALLATION_ID:-}" ]    || die "GITHUB_APP_INSTALLATION_ID not set"

        request_installation_token
        ;;
    *)
        die "usage: github-app-token.sh {get|refresh}"
        ;;
esac
