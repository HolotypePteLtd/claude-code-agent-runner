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

# Setup SSH configuration if keys are available
setup_ssh() {
    if [ -d "/home/runner/.ssh" ]; then
        # Check if any SSH keys exist
        if [ -f "/home/runner/.ssh/id_ed25519" ] || [ -f "/home/runner/.ssh/id_rsa" ]; then
            log_info "SSH keys detected, configuring SSH for GitHub..."

            # Ensure proper permissions
            chmod 700 /home/runner/.ssh
            chmod 600 /home/runner/.ssh/id_* 2>/dev/null || true
            chmod 644 /home/runner/.ssh/*.pub 2>/dev/null || true

            # Add GitHub to known_hosts if not already present
            if ! grep -q "github.com" /home/runner/.ssh/known_hosts 2>/dev/null; then
                log_info "Adding GitHub to known_hosts..."
                mkdir -p /home/runner/.ssh
                ssh-keyscan github.com >> /home/runner/.ssh/known_hosts 2>/dev/null
            fi

            # Test SSH connection
            if ssh -o BatchMode=yes -o ConnectTimeout=5 git@github.com &>/dev/null; then
                log_info "SSH connection to GitHub successful!"
            else
                log_warn "SSH keys found but connection to GitHub failed. SSH operations may not work."
            fi
        else
            log_info "No SSH keys found in /home/runner/.ssh, SSH not configured."
        fi
    fi
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

# Obtain runner registration token
# If GITHUB_PAT is set, auto-generate a fresh registration token via the API
# Otherwise fall back to GITHUB_RUNNER_TOKEN (which expires after ~1 hour)
if [ -n "$GITHUB_PAT" ]; then
    log_info "Generating fresh runner registration token using PAT..."
    if [ -n "$GITHUB_REPO" ]; then
        # Repo-level runner
        API_URL="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/actions/runners/registration-token"
    else
        # Org-level runner
        API_URL="https://api.github.com/orgs/${GITHUB_OWNER}/actions/runners/registration-token"
    fi
    RESPONSE=$(curl -s -X POST \
        -H "Authorization: Bearer ${GITHUB_PAT}" \
        -H "Accept: application/vnd.github+json" \
        "$API_URL")
    GITHUB_RUNNER_TOKEN=$(echo "$RESPONSE" | jq -r '.token')
    if [ -z "$GITHUB_RUNNER_TOKEN" ]; then
        log_error "Failed to generate registration token. API response:"
        echo "$RESPONSE"
        exit 1
    fi
    log_info "Registration token obtained successfully"
else
    log_error "GITHUB_PAT must be set"
    exit 1
fi

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

# Inject SSH key from base64 env var if provided
if [ -n "$SSH_PRIVATE_KEY_BASE64" ]; then
    log_info "Injecting SSH key from SSH_PRIVATE_KEY_BASE64 env var..."
    mkdir -p /home/runner/.ssh
    echo "$SSH_PRIVATE_KEY_BASE64" | base64 -d > /home/runner/.ssh/id_ed25519
    chmod 600 /home/runner/.ssh/id_ed25519
fi

# Configure SSH if keys are available
setup_ssh

log_info "Runner configured successfully!"
log_info "Starting runner..."

# Start the runner
exec ./run.sh
