#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Change to project root directory (parent of .github)
# Get the absolute path of the script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
cd "$PROJECT_ROOT"

# Check for Docker
if ! command -v docker &> /dev/null; then
    log_error "Docker is not installed. Please install Docker first."
    exit 1
fi

log_info "Docker is installed: $(docker --version)"

# Check for docker-compose
if ! command -v docker-compose &> /dev/null; then
    log_error "docker-compose is not installed. Please install docker-compose first."
    exit 1
fi

log_info "docker-compose is installed: $(docker-compose --version)"

# Check if .env file exists
ENV_FILE=".github/workflows/.env"
if [ -f "$ENV_FILE" ]; then
    log_warn ".env file already exists at $ENV_FILE"
    read -p "Do you want to overwrite it? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Using existing .env file"
    else
        rm "$ENV_FILE"
        log_info "Removed existing .env file"
    fi
fi

# Create .env file if it doesn't exist
if [ ! -f "$ENV_FILE" ]; then
    log_step "Creating .env file at $ENV_FILE..."

    # Ensure the directory exists
    mkdir -p "$(dirname "$ENV_FILE")"

    # GitHub owner/org URL
    echo ""
    log_info "For organization-level runners, use your GitHub organization URL"
    log_info "For single-repo runners, use the repository URL"
    read -p "Enter GitHub owner/org URL: " GITHUB_OWNER_URL
    if [ -z "$GITHUB_OWNER_URL" ]; then
        log_error "GitHub owner/org URL is required"
        exit 1
    fi

    # GitHub runner token
    echo ""
    log_info "Get a runner token from your repo/org Settings > Actions > Runners"
    log_info "Click 'New self-hosted runner' and copy the token (not the entire ./config.sh command)"
    read -p "Enter GitHub runner token: " GITHUB_RUNNER_TOKEN

    # Runner name
    read -p "Enter runner name [claude-docker-runner]: " GITHUB_RUNNER_NAME
    GITHUB_RUNNER_NAME=${GITHUB_RUNNER_NAME:-claude-docker-runner}

    # Anthropic API key
    echo ""
    read -p "Enter Anthropic API key: " ANTHROPIC_AUTH_TOKEN

    # Git config
    GIT_AUTHOR_NAME="Claude Code Planning Agent"
    GIT_AUTHOR_EMAIL="claude-planning@github-actions.local"

    # Write .env file
    cat > "$ENV_FILE" << EOF
# GitHub Configuration
# For org-level: use https://github.com/your-org
# For single-repo: use https://github.com/your-org/your-repo
GITHUB_OWNER_URL=${GITHUB_OWNER_URL}
GITHUB_RUNNER_TOKEN=${GITHUB_RUNNER_TOKEN}
GITHUB_RUNNER_NAME=${GITHUB_RUNNER_NAME}
GITHUB_RUNNER_LABELS=docker,ubuntu,flutter
GITHUB_RUNNER_GROUP=default

# Claude Configuration
ANTHROPIC_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN}

# Git Configuration
GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME}
GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL}
EOF

    log_info "Created .env file"
fi

# Build and start the container
log_step "Building Docker image..."
docker-compose -f docker-compose.runner.yml build

log_step "Starting container..."
docker-compose -f docker-compose.runner.yml up -d

log_info "Container started successfully!"
echo ""
log_info "Next steps:"
log_info "1. Check runner status: docker-compose -f docker-compose.runner.yml ps"
log_info "2. View logs: docker-compose -f docker-compose.runner.yml logs -f"
log_info "3. Stop runner: docker-compose -f docker-compose.runner.yml down"
echo ""
log_info "Verify runner is registered in your repo/org Settings > Actions > Runners"
