FROM node:22-bookworm-slim

# Architecture mapping: docker arm64 → wtp arm64, docker amd64 → wtp x86_64
ARG TARGETARCH
RUN echo "Building for architecture: ${TARGETARCH}"

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    jq \
    python3 \
    python3-pip \
    imagemagick \
    xvfb \
    xauth \
    chromium \
    fonts-liberation \
    libasound2 \
    libatk-bridge2.0-0 \
    libatk1.0-0 \
    libatspi2.0-0 \
    libcups2 \
    libdbus-1-3 \
    libdrm2 \
    libgbm1 \
    libgtk-3-0 \
    libnspr4 \
    libnss3 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxkbcommon0 \
    libxrandr2 \
    xdg-utils \
    ffmpeg \
    clang \
    mold \
    && rm -rf /var/lib/apt/lists/*

# pnpm
RUN npm install -g pnpm@10.28.0 && npm cache clean --force

# Claude CLI + agent-browser (skills are bundled in the package — no runtime download needed)
RUN npm install -g @anthropic-ai/claude-code agent-browser@0.26.0 && npm cache clean --force

# wtp — architecture-aware installation
RUN case "${TARGETARCH}" in \
      arm64) WTP_ARCH="arm64" ;; \
      amd64) WTP_ARCH="x86_64" ;; \
      *) echo "Unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    curl -fsSL "https://github.com/satococoa/wtp/releases/download/v2.10.3/wtp_2.10.3_linux_${WTP_ARCH}.deb" \
      -o /tmp/wtp.deb && \
    dpkg -i /tmp/wtp.deb && \
    rm /tmp/wtp.deb

# sccache — compiler cache for Rust builds
RUN case "${TARGETARCH}" in \
      arm64) SCCACHE_ARCH="aarch64-unknown-linux-musl" ;; \
      amd64) SCCACHE_ARCH="x86_64-unknown-linux-musl" ;; \
      *) echo "Unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    curl -fsSL "https://github.com/mozilla/sccache/releases/download/v0.8.2/sccache-v0.8.2-${SCCACHE_ARCH}.tar.gz" \
      -o /tmp/sccache.tar.gz && \
    tar xzf /tmp/sccache.tar.gz -C /tmp && \
    mv "/tmp/sccache-v0.8.2-${SCCACHE_ARCH}/sccache" /usr/local/bin/sccache && \
    chmod +x /usr/local/bin/sccache && \
    rm -rf /tmp/sccache.tar.gz "/tmp/sccache-v0.8.2-${SCCACHE_ARCH}"

# Bake autoframe agent scripts + Claude commands into the image.
# The entrypoint copies these into the cloned repo if setup.sh hasn't been run.
COPY scripts /opt/autoframe/scripts
RUN chmod +x /opt/autoframe/scripts/*.sh
COPY .claude/commands /opt/autoframe/commands
COPY spec-loop /opt/autoframe/spec-loop
RUN chmod +x /opt/autoframe/spec-loop/*.sh
COPY workflow.toml /opt/autoframe/workflow.toml

# Bake the autoframe Node.js engine so node-based agents (e.g. slack-listen)
# can run from /opt/autoframe without touching the cloned workspace repo.
COPY package.json pnpm-lock.yaml /opt/autoframe/
COPY main.js /opt/autoframe/
COPY core /opt/autoframe/core
COPY adapters /opt/autoframe/adapters
RUN cd /opt/autoframe && pnpm install --frozen-lockfile --prod

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# sips shim — macOS-only command replaced with ImageMagick
COPY scripts/sips /usr/local/bin/sips
RUN chmod +x /usr/local/bin/sips

# Chromium wrapper — prepends --no-sandbox flags required in Docker; used by agent-browser
COPY scripts/chromium-container /usr/local/bin/chromium-container
RUN chmod +x /usr/local/bin/chromium-container
ENV AGENT_BROWSER_EXECUTABLE_PATH=/usr/local/bin/chromium-container

# OpenRouter compatibility proxy — strips proprietary tool types OpenRouter rejects
COPY scripts/or-proxy.py /usr/local/bin/or-proxy.py
RUN chmod +x /usr/local/bin/or-proxy.py

# Non-root user required: --dangerously-skip-permissions is blocked for root
RUN useradd -u 1001 -m -s /bin/bash agent \
    && mkdir -p /workspace/repo /cache \
    && chown -R agent:agent /workspace /cache

USER agent

# Rust toolchain installed under agent home (not /root)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y \
      --default-toolchain 1.95.0 \
      --profile minimal \
      --no-modify-path && \
    /home/agent/.cargo/bin/rustup component add rustfmt clippy --toolchain 1.95.0 && \
    rm -rf /home/agent/.rustup/toolchains/*/share/doc \
           /home/agent/.rustup/toolchains/*/share/man \
           /home/agent/.rustup/tmp \
           /home/agent/.rustup/downloads

# Use mold for faster Rust linking; sccache wraps rustc to cache compilation artifacts
RUN printf '[build]\nrustflags = ["-C", "linker=clang", "-C", "link-arg=-fuse-ld=mold"]\n' \
    > /home/agent/.cargo/config.toml

ENV RUSTC_WRAPPER=sccache \
    SCCACHE_DIR=/cache/sccache \
    CARGO_INCREMENTAL=0

ENV PATH="/home/agent/.cargo/bin:$PATH"

# ── Docker-in-Docker ──────────────────────────────────────────────────────────
# Re-enter root to install the daemon and gosu (Rust toolchain above ran as agent).
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    docker.io \
    gosu \
    && rm -rf /var/lib/apt/lists/*

# agent needs docker group membership to reach the socket after privilege drop
RUN usermod -aG docker agent

# Anonymous volume so overlay2 runs on a real fs (not the container's overlayfs root).
# Each scaled replica gets its own — a named volume would corrupt shared state.
VOLUME /var/lib/docker

COPY scripts/entrypoint-dind.sh /usr/local/bin/entrypoint-dind.sh
RUN chmod +x /usr/local/bin/entrypoint-dind.sh

ENTRYPOINT ["/usr/local/bin/entrypoint-dind.sh", "/usr/local/bin/entrypoint.sh"]
