FROM node:22-bookworm

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
    && rm -rf /var/lib/apt/lists/*

# pnpm
RUN npm install -g pnpm@10.28.0

# Claude CLI + agent-browser (skills are bundled in the package — no runtime download needed)
RUN npm install -g @anthropic-ai/claude-code agent-browser@0.26.0

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

# Linear MCP server (uses LINEAR_API_KEY, no OAuth required)
COPY linear-mcp /opt/linear-mcp
RUN cd /opt/linear-mcp && npm install --omit=dev

# Bake autoframe agent scripts + Claude commands into the image.
# The entrypoint copies these into the cloned repo if setup.sh hasn't been run.
COPY scripts /opt/autoframe/scripts
RUN chmod +x /opt/autoframe/scripts/*.sh
COPY .claude/commands /opt/autoframe/commands

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
    /home/agent/.cargo/bin/rustup component add rustfmt clippy --toolchain 1.95.0

ENV PATH="/home/agent/.cargo/bin:$PATH"

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
