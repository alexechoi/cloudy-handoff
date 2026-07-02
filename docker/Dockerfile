# cloudy-handoff agent-runtime image.
#
# A Debian-based image that mirrors a local dev machine closely enough for
# Claude Code / Codex to work the same way in the cloud: git, ripgrep, a real
# glibc, build tools, a headless Chromium (via Playwright), and the gcloud CLI.
#
# Build context is the repo ROOT (see deploy/cloudbuild.yaml).
FROM node:22-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers \
    CLOUDY_HANDOFF_HOME=/opt/cloudy-handoff \
    NODE_ENV=production

# --- system tooling ---------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
      git ripgrep jq curl ca-certificates gnupg unzip less procps \
      python3 python3-venv build-essential openssh-client \
    && rm -rf /var/lib/apt/lists/*

# --- gcloud CLI (lean, no bundled python/components) ------------------------
RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
      > /etc/apt/sources.list.d/google-cloud-sdk.list \
    && curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
      | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
    && apt-get update && apt-get install -y --no-install-recommends google-cloud-cli \
    && rm -rf /var/lib/apt/lists/*

# --- agent CLIs -------------------------------------------------------------
RUN npm install -g @anthropic-ai/claude-code @openai/codex \
    && npm cache clean --force

# --- headless Chromium via Playwright (Chromium only, with system deps) -----
RUN npm install -g playwright \
    && npx --yes playwright install --with-deps chromium \
    && rm -rf /var/lib/apt/lists/*

# --- non-root runtime user --------------------------------------------------
RUN useradd --create-home --shell /bin/bash agent \
    && mkdir -p /workspace "${CLOUDY_HANDOFF_HOME}" /secrets/codex \
    && chown -R agent:agent /workspace "${CLOUDY_HANDOFF_HOME}"

# --- app files --------------------------------------------------------------
COPY scripts/ ${CLOUDY_HANDOFF_HOME}/scripts/
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
      ${CLOUDY_HANDOFF_HOME}/scripts/*.sh 2>/dev/null || true

USER agent
WORKDIR /workspace
ENV HOME=/home/agent

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
