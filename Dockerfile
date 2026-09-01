# ── Prod-Stage: OpenClaw-Gateway (Default-Target) ────────────────
# Schlankes Gateway-Image. Kein JDK, keine Dev-Toolchain — die gibt's
# nur in der Dev-Stage weiter unten (`docker build --target dev`).
# Pinned: `openclaw/openclaw:slim` floats to the newest runtime, which hard-fails
# on a stale config schema (2026.8.1 rejects 2026.7.1-era keys like agents.list,
# agents.defaults.memorySearch, meta.lastTouchedAt). Pin to a specific release so
# runtime + config schema stay in lockstep; bump both together when upgrading.
#
# 2026.7.1-stable filtered GH_TOKEN/GITHUB_TOKEN out of exec-tool child envs
# (host-env security policy); the upstream "Native GitHub identity" exception
# landed in 2026.8.1-beta.3 and is included in stable 2026.8.1, so this pin also
# guarantees GH_TOKEN reaches exec/sub-agent shells. Details: docs/gh-token-exec-env.md.
FROM openclaw/openclaw:2026.8.1-slim AS prod

# Switch to root for package installs
USER root

# Install git, SSH, GitHub CLI
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    openssh-client \
    curl \
    jq \
    pkg-config \
    libssl-dev \
    libsqlite3-dev \
    python3-pip \
    python3-venv \
    sshpass \
    gosu \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Rust toolchain via rustup (pinned). Debian bookworm apt ships rustc 1.63 /
# cargo 1.65 — too old for Rust edition 2024 (MSRV >= 1.85). Installed into
# node's home so the runtime `node` user can use it (the image runs as `node`);
# the explicit chown + PATH keep `which cargo rustc` green for every user.
ENV RUSTUP_HOME=/home/node/.rustup \
    CARGO_HOME=/home/node/.cargo
RUN mkdir -p /home/node \
    && curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain 1.98.0 \
    && chown -R node:node /home/node/.cargo /home/node/.rustup
ENV PATH="/home/node/.cargo/bin:${PATH}"

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Configure git for the coding agent. Write directly to the runtime `node`
# user's global config (/home/node/.gitconfig). `--system` is unreliable here
# (build cache / base-image git prefix), and `--global` during build would write
# /root/.gitconfig, which the agent never reads.
RUN mkdir -p /home/node \
    && git config --file /home/node/.gitconfig user.name "Molty 🦞" \
    && git config --file /home/node/.gitconfig user.email "molty@openclaw.simonklimke.de" \
    && git config --file /home/node/.gitconfig init.defaultBranch main \
    && chown -R node:node /home/node

# Create SSH config directory and disable strict host key checking for internal hosts
RUN mkdir -p /home/node/.ssh && chown -R node:node /home/node/.ssh
COPY --chown=node:node ssh_config /home/node/.ssh/config

# Make repos working directory
RUN mkdir -p /home/node/repos && chown node:node /home/node/repos

# ── Extra CLI tools for skills ──────────────────────────────────
# Install himalaya (email CLI) — prebuilt binary
RUN curl -fsSL https://github.com/pimalaya/himalaya/releases/download/v2.0.0/himalaya.x86_64-linux.tgz | tar xz -C /tmp && mv /tmp/himalaya /usr/local/bin/ && chmod +x /usr/local/bin/himalaya

# Install Ansible (for deploying user projects)
RUN pip3 install --break-system-packages ansible


# ── Entrypoint: sync git config into runtime home ────────────────
COPY --chown=node:node entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# ── GitHub App auth helpers (entrypoint step 5c + coding agents) ──
# gh-app-auth.sh fetches a fresh ~1h installation token from the momo-bot
# GitHub App and seeds gh/git auth; agents re-run it when a token expired.
COPY --chown=node:node scripts/generate-github-token.sh scripts/gh-app-auth.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/generate-github-token.sh /usr/local/bin/gh-app-auth.sh

# ── External provider plugins (deepseek + groq) ────────────────────
# deepseek and groq are NOT bundled in 2026.8.1 (unlike deepgram/google) —
# they ship as official external npm packages. Bake them into the image so a
# FRESH openclaw_home volume works out of the box. Docker only seeds a named
# volume from image content on FIRST use, so pre-existing volumes are
# converged idempotently by entrypoint.sh (step 5d) instead. Pinned to the
# runtime version so plugin + config schema stay in lockstep.
USER node
RUN openclaw plugins install @openclaw/deepseek-provider@2026.8.1 --force --accept-capabilities --pin \
 && openclaw plugins install @openclaw/groq-provider@2026.8.1 --force --accept-capabilities --pin
USER root

ENTRYPOINT ["/entrypoint.sh"]
CMD ["node", "openclaw.mjs", "gateway"]


# ════════════════════════════════════════════════════════════════
# Dev-Stage: headless Minecraft-Mod-Entwicklung (create:yogglez)
# ════════════════════════════════════════════════════════════════
# Baut auf dem Prod-Image auf (git/gh/ssh/curl sind bereits drin) und
# ergänzt die Java-21-Toolchain (Temurin) für NeoForge-Mods (MC 1.21.1,
# NeoForge 21.1.217, Gradle 9.2.1 via Wrapper). Das Prod-Image bleibt
# unverändert schlank — JDK gibt's nur hier.
#
#   docker build --target dev -t openclaw-dev .
#
# Nur HEADLESS Gradle-Tasks sind sinnvoll: compileJava, test, runData,
# gameTestServer, runServer. `runClient` braucht ein Display → im
# Devcontainer nicht nutzbar (kein X-Server).
FROM prod AS dev

USER root

# Temurin JDK 21 (LTS) — passt zur harten Java-21-Toolchain der
# NeoForge-Mods. Rolling "latest 21 LTS" vom Adoptium-API (Vendor
# eclipse = Temurin); Arch wird aus dpkg abgeleitet (x64/aarch64).
RUN set -eux; \
    ARCH="$(dpkg --print-architecture | sed 's/amd64/x64/; s/arm64/aarch64/')"; \
    curl -fsSL "https://api.adoptium.net/v3/binary/latest/21/ga/linux/${ARCH}/jdk/hotspot/normal/eclipse" -o /tmp/jdk21.tar.gz; \
    mkdir -p /opt/java; \
    tar -xzf /tmp/jdk21.tar.gz -C /opt/java --strip-components=1; \
    rm /tmp/jdk21.tar.gz; \
    /opt/java/bin/java -version; \
    /opt/java/bin/javac -version

ENV JAVA_HOME=/opt/java \
    PATH="/opt/java/bin:${PATH}"

# Persistenter Gradle-Cache: /home/node/.gradle (GRADLE_USER_HOME) als
# Named Volume mounten (docker-compose.dev.yml). NeoForge-Deps sind
# 2–4 GB — ohne Volume würde jeder Container-Start sie neu laden.
RUN mkdir -p /home/node/.gradle /home/node/repos \
    && chown -R node:node /home/node/.gradle /home/node/repos

# Headless-Devcontainer: kein Gateway-Start, nur eine Shell. Der
# Prod-ENTRYPOINT (entrypoint.sh) läuft weiter (no-ops ohne die
# Config-Mounts von Prod) und droppt via gosu auf User `node` —
# Gradle läuft also als `node`, Dateien im repos-Volume matchen.
CMD ["/bin/bash"]


# ════════════════════════════════════════════════════════════════
# Default-Target bleibt Prod.
# Die bestehende Pipeline (build.yml, test-branch.sh) baut OHNE
# `--target` und bekommt so weiterhin das schlanke Prod-Image — die
# Dev-Stage wird explizit via `docker build --target dev` gewählt.
# ════════════════════════════════════════════════════════════════
FROM prod
LABEL org.opencontainers.image.title="openclaw-deploy (prod)" \
      org.opencontainers.image.description="OpenClaw gateway image; dev toolchain: docker build --target dev"
