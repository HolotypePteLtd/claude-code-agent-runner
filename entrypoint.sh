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

# Check required environment variables
if [ -z "$GITHUB_RUNNER_TOKEN" ]; then
    log_error "GITHUB_RUNNER_TOKEN is not set"
    exit 1
fi

GITHUB_RUNNER_NAME=${GITHUB_RUNNER_NAME:-claude-docker-runner}

# Determine the runner URL: prefer repo URL, fall back to owner URL
if [ -n "$GITHUB_REPO_URL" ]; then
    GITHUB_RUNNER_URL="$GITHUB_REPO_URL"
    log_info "Setting up repository-level runner for: ${GITHUB_REPO_URL}"
    log_info "Runner will only process jobs from this repository"
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

log_info "Runner name: ${GITHUB_RUNNER_NAME}"

# Check if already configured
if [ -f ".runner" ]; then
    log_info "Runner already configured, starting..."

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

    # Start the runner
    exec ./run.sh
else
    log_info "First-time setup, downloading and configuring runner..."

    # Get the latest runner version (with fallback for API rate limits)
    FALLBACK_RUNNER_VERSION="2.331.0"
    LATEST_VERSION=$(curl -s "https://api.github.com/repos/actions/runner/releases/latest" | jq -r '.tag_name // empty' | sed 's/v//')
    if [ -z "$LATEST_VERSION" ]; then
        log_warn "Could not fetch latest runner version from GitHub API (rate limited?), using fallback: ${FALLBACK_RUNNER_VERSION}"
        LATEST_VERSION="$FALLBACK_RUNNER_VERSION"
    fi
    log_info "Runner version: ${LATEST_VERSION}"

    # Download the runner
    RUNNER_ARCH="x64"
    RUNNER_OS="linux"
    DOWNLOAD_URL="https://github.com/actions/runner/releases/download/v${LATEST_VERSION}/actions-runner-${RUNNER_OS}-${RUNNER_ARCH}-${LATEST_VERSION}.tar.gz"

    log_info "Downloading runner from: ${DOWNLOAD_URL}"
    curl -o actions-runner.tar.gz -L ${DOWNLOAD_URL}

    # Extract the runner
    log_info "Extracting runner..."
    tar xzf ./actions-runner.tar.gz
    rm actions-runner.tar.gz

    # Configure the runner
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
fi
