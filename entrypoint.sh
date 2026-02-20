#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Ensure GitHub is in known_hosts (needed by actions/checkout even for HTTPS)
setup_known_hosts() {
    mkdir -p /home/runner/.ssh
    chmod 700 /home/runner/.ssh
    if ! grep -q "github.com" /home/runner/.ssh/known_hosts 2>/dev/null; then
        log_info "Adding GitHub to known_hosts..."
        ssh-keyscan github.com >> /home/runner/.ssh/known_hosts 2>/dev/null
    fi
}

# Setup GitHub App authentication for git operations
setup_github_app() {
    log_info "Configuring GitHub App authentication for git..."

    local token
    if ! token=$(github-app-token.sh get 2>&1); then
        log_error "GitHub App token generation failed: ${token}"
        exit 1
    fi

    log_info "GitHub App installation token generated successfully!"

    # Configure git credential helper for HTTPS
    git config --global credential.helper '/usr/local/bin/git-credential-github-app.sh'

    # Remove any reverse insteadOf rules (SSH←HTTPS) that may have been added
    # by tools like Claude Code and persisted via volume mounts
    git config --global --unset-all url."git@github.com:".insteadOf 2>/dev/null || true
    git config --global --unset-all url."ssh://git@github.com/".insteadOf 2>/dev/null || true

    # Rewrite SSH URLs to HTTPS so the credential helper is used
    git config --global url."https://github.com/".insteadOf "git@github.com:"

    # Authenticate gh CLI with the token
    if echo "$token" | gh auth login --with-token 2>/dev/null; then
        log_info "gh CLI authenticated via GitHub App token."
    else
        log_warn "gh CLI authentication with GitHub App token failed."
    fi

    # Start background loop to refresh the gh CLI token every 45 minutes
    (
        while true; do
            sleep 2700  # 45 minutes
            if refresh_token=$(github-app-token.sh refresh 2>/dev/null); then
                echo "$refresh_token" | gh auth login --with-token 2>/dev/null \
                    && log_info "gh CLI token refreshed via GitHub App." \
                    || log_warn "gh CLI token refresh failed."
            else
                log_warn "GitHub App token refresh failed."
            fi
        done
    ) &

    log_info "GitHub App authentication configured."
}

# Setup mode: pause for manual configuration (e.g. claude login)
if [ "${SETUP_MODE}" = "true" ] || [ "${SETUP_MODE}" = "1" ]; then
    log_info "=== SETUP MODE ==="
    log_info "Container is paused for manual configuration."
    log_info "Open a terminal to this container and run 'claude' to authenticate."
    log_info "Once done, remove the SETUP_MODE env var and redeploy."
    log_info "Credentials will persist in the claude-config volume."
    # Keep container alive so you can exec into it
    exec sleep infinity
fi

GITHUB_RUNNER_NAME=${GITHUB_RUNNER_NAME:-claude-docker-runner}

# Determine the runner URL and org/repo context
if [ -n "$GITHUB_REPO_URL" ]; then
    GITHUB_RUNNER_URL="$GITHUB_REPO_URL"
    log_info "Setting up repository-level runner for: ${GITHUB_REPO_URL}"
    log_info "Runner will only process jobs from this repository"
    # Extract owner/repo for API calls
    if [[ $GITHUB_REPO_URL =~ github\.com/([^/]+)/([^/]+) ]]; then
        GITHUB_OWNER="${BASH_REMATCH[1]}"
        GITHUB_REPO="${BASH_REMATCH[2]}"
    fi
elif [ -n "$GITHUB_OWNER_URL" ]; then
    GITHUB_RUNNER_URL="$GITHUB_OWNER_URL"
    if [[ $GITHUB_OWNER_URL =~ github\.com/([^/]+) ]]; then
        GITHUB_OWNER="${BASH_REMATCH[1]}"
        log_info "Setting up organization-level runner for: ${GITHUB_OWNER}"
        log_info "Runner will process jobs from all repositories in ${GITHUB_OWNER}"
    fi
else
    log_error "Either GITHUB_REPO_URL or GITHUB_OWNER_URL must be set"
    exit 1
fi

# Obtain runner registration token using GitHub App installation token
log_info "Generating GitHub App token for runner registration..."
APP_TOKEN=$(github-app-token.sh get 2>&1) || {
    log_error "Failed to generate GitHub App token: ${APP_TOKEN}"
    exit 1
}

if [ -n "$GITHUB_REPO" ]; then
    API_URL="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/actions/runners/registration-token"
else
    API_URL="https://api.github.com/orgs/${GITHUB_OWNER}/actions/runners/registration-token"
fi

RESPONSE=$(curl -s -X POST \
    -H "Authorization: Bearer ${APP_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "$API_URL")
GITHUB_RUNNER_TOKEN=$(echo "$RESPONSE" | jq -r '.token')
if [ -z "$GITHUB_RUNNER_TOKEN" ] || [ "$GITHUB_RUNNER_TOKEN" = "null" ]; then
    log_error "Failed to generate registration token. API response:"
    echo "$RESPONSE"
    exit 1
fi
log_info "Registration token obtained successfully"

log_info "Runner name: ${GITHUB_RUNNER_NAME}"

# Always remove old configuration and reconfigure fresh
# This prevents stale registration issues when tokens expire
if [ -f ".runner" ]; then
    log_info "Removing old runner configuration to re-register fresh..."
    ./config.sh remove --token "${GITHUB_RUNNER_TOKEN}" 2>/dev/null || rm -f .runner .credentials .credentials_rsaparams
fi

log_info "Configuring runner..."
./config.sh \
    --url "${GITHUB_RUNNER_URL}" \
    --token "${GITHUB_RUNNER_TOKEN}" \
    --name "${GITHUB_RUNNER_NAME}" \
    --labels "${GITHUB_RUNNER_LABELS:-docker,ubuntu,flutter}" \
    --work "_work" \
    --unattended \
    --replace

# Configure git
git config --global user.name "${GIT_AUTHOR_NAME:-Claude Code Planning Agent}"
git config --global user.email "${GIT_AUTHOR_EMAIL:-claude-planning@github-actions.local}"

# Always ensure GitHub is in known_hosts
setup_known_hosts

# Configure GitHub App authentication (if env vars are set)
setup_github_app

log_info "Runner configured successfully!"
log_info "Starting runner..."

# Start the runner
exec ./run.sh
