FROM openclaw/openclaw:slim

# Switch to root for package installs
USER root

# Install git, SSH, GitHub CLI, and Rust
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    openssh-client \
    curl \
    cargo \
    rustc \
    pkg-config \
    libssl-dev \
    libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Configure git for the coding agent
RUN git config --global user.name "Molty 🦞" \
    && git config --global user.email "molty@openclaw.simonklimke.de" \
    && git config --global init.defaultBranch main

# Create SSH config directory and disable strict host key checking for internal hosts
RUN mkdir -p /home/node/.ssh && chown -R node:node /home/node/.ssh
COPY --chown=node:node ssh_config /home/node/.ssh/config

# Make repos working directory
RUN mkdir -p /home/node/repos && chown node:node /home/node/repos

# ── Extra CLI tools for skills ──────────────────────────────────
# Install himalaya (email CLI) — prebuilt binary
RUN curl -fsSL https://github.com/pimalaya/himalaya/releases/download/v2.0.0/himalaya.x86_64-linux.tgz | tar xz -C /tmp && mv /tmp/himalaya /usr/local/bin/ && chmod +x /usr/local/bin/himalaya

# Install gifgrep (GIF search) — compile from source
RUN cargo install gifgrep 2>/dev/null || echo "gifgrep not available — skipping"

# Back to non-root user
USER node
