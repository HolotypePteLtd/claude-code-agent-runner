# Dockerfile for GitHub Actions Self-Hosted Runner
# Based on Ubuntu 24.04 with Flutter, Node.js, and Claude Code CLI

FROM ubuntu:24.04

# Avoid prompts from apt
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies (including OpenSSH for SSH key authentication)
RUN apt-get update && apt-get install -y \
    curl \
    git \
    jq \
    unzip \
    xz-utils \
    zip \
    libglu1-mesa \
    libicu74 \
    libssl3 \
    openssl \
    openssh-client \
    clang cmake ninja-build pkg-config libc++-dev libc++abi-dev \
    libgtk-3-dev \
    xvfb \
    ffmpeg libavformat-dev libavcodec-dev libavutil-dev libswscale-dev \
    libx264-dev libx265-dev \
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libasound2-dev lld \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js LTS
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && \
    apt-get install -y gh && \
    rm -rf /var/lib/apt/lists/*

# Install Flutter SDK
ENV FLUTTER_VERSION=3.41.0
ENV FLUTTER_HOME=/opt/flutter
ENV PATH="${FLUTTER_HOME}/bin:${PATH}"

RUN curl -L "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
      -o /tmp/flutter.tar.xz && \
    mkdir -p ${FLUTTER_HOME} && \
    tar xf /tmp/flutter.tar.xz -C ${FLUTTER_HOME} --strip-components=1 && \
    rm /tmp/flutter.tar.xz && \
    git config --global --add safe.directory ${FLUTTER_HOME} && \
    git config --global user.name "Flutter Runner" && \
    git config --global user.email "runner@docker.local"

# Create runner user
RUN useradd -m -s /bin/bash runner

# Install Claude Code CLI using npm (like official devcontainer)
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin
RUN npm install -g @anthropic-ai/claude-code

# Set ownership of Flutter directory to runner user
RUN chown -R runner:runner ${FLUTTER_HOME}

# Create and set ownership of Claude config directory
RUN mkdir -p /home/runner/.claude && \
    chown -R runner:runner /home/runner/.claude

# Create .ssh directory for SSH keys
RUN mkdir -p /home/runner/.ssh && \
    chown -R runner:runner /home/runner/.ssh && \
    chmod 700 /home/runner/.ssh

# Install GitHub Actions Runner
RUN ACTIONS_RUNNER_VERSION="2.331.0" && \
    DOWNLOAD_URL="https://github.com/actions/runner/releases/download/v${ACTIONS_RUNNER_VERSION}/actions-runner-linux-x64-${ACTIONS_RUNNER_VERSION}.tar.gz" && \
    curl -o /tmp/actions-runner.tar.gz -L ${DOWNLOAD_URL} && \
    mkdir -p /actions-runner && \
    tar xzf /tmp/actions-runner.tar.gz -C /actions-runner && \
    rm /tmp/actions-runner.tar.gz

# Create working directory for actions runner
WORKDIR /actions-runner

# Copy entrypoint script and GitHub App helper scripts
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=755 github-app-token.sh /usr/local/bin/github-app-token.sh
COPY --chmod=755 git-credential-github-app.sh /usr/local/bin/git-credential-github-app.sh
COPY --chmod=755 cleanup-git-config.sh /usr/local/bin/cleanup-git-config.sh

# Set up runner user permissions
RUN chown -R runner:runner /actions-runner

# Switch to runner user
USER runner

# Set up environment for runner user
ENV PATH="${FLUTTER_HOME}/bin:/home/runner/.local/bin:/usr/local/share/npm-global/bin:${PATH}"
ENV HOME=/home/runner
ENV CLAUDE_CONFIG_DIR=/home/runner/.claude
ENV ACTIONS_RUNNER_HOOK_JOB_STARTED=/usr/local/bin/cleanup-git-config.sh

# Configure Flutter as runner user
RUN flutter config --no-analytics && \
    flutter precache

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
