#!/bin/bash
# git-credential-github-app.sh — Git credential helper for GitHub App tokens
#
# Configured via: git config --global credential.helper /usr/local/bin/git-credential-github-app.sh
#
# Git calls this with one of: get, store, erase
# Only "get" is meaningful — store/erase are no-ops since the token
# lifecycle is managed by github-app-token.sh's cache.

case "${1:-}" in
    get)
        # Read stdin to check if this is for github.com
        while IFS='=' read -r key value; do
            case "$key" in
                host) host="$value" ;;
            esac
        done

        if [ "${host:-}" != "github.com" ]; then
            exit 0
        fi

        token=$(/usr/local/bin/github-app-token.sh get 2>/dev/null) || exit 0

        printf 'protocol=https\nhost=github.com\nusername=x-access-token\npassword=%s\n' "$token"
        ;;
    store|erase)
        # No-ops — token lifecycle managed by cache
        ;;
esac
