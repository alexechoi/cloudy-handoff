# cloudy-handoff configuration — copy to `.cloudy-handoff.env` and edit.
#
#   cp deploy/config.example.sh .cloudy-handoff.env
#   $EDITOR .cloudy-handoff.env
#
# All scripts source this file. Anything left unset falls back to a sensible
# default (see scripts/lib/gcp.sh :: load_config). The only value that really
# matters is PROJECT_ID, and even that defaults to your active gcloud project.

# --- GCP target -------------------------------------------------------------
# Your own GCP project. Defaults to `gcloud config get-value project`.
export PROJECT_ID="${PROJECT_ID:-}"

# Region for Cloud Run, Artifact Registry and the Firestore database.
export REGION="${REGION:-us-central1}"

# --- Resource names (safe defaults; override only if they collide) ----------
export JOB_NAME="${JOB_NAME:-cloudy-handoff}"
export AR_REPO="${AR_REPO:-cloudy-handoff}"
export SA_NAME="${SA_NAME:-cloudy-handoff}"
# GCS bucket for transcripts / patches / logs. Must be globally unique;
# default derives from the project id.
export BUCKET="${BUCKET:-${PROJECT_ID:-unset}-cloudy-handoff}"
# Firestore database id. Leave as the default database.
export FIRESTORE_DATABASE="${FIRESTORE_DATABASE:-(default)}"

# --- Container image --------------------------------------------------------
# If empty (default), bootstrap uses the public prebuilt image (fast: Cloud Run
# pulls it directly, no build). `cloudy-handoff bootstrap --build` instead builds
# from source (docker/Dockerfile) into your OWN Artifact Registry. Set IMAGE to
# pin a specific published image.
export IMAGE="${IMAGE:-}"
# Override only if you fork/host your own public image.
export PREBUILT_IMAGE="${PREBUILT_IMAGE:-us-central1-docker.pkg.dev/cloudy-handoff-public/images/cloudy-handoff:latest}"

# --- Job sizing / limits ----------------------------------------------------
export CPU="${CPU:-2}"
export MEMORY="${MEMORY:-8Gi}"
# Cloud Run Job task timeout (max 168h/604800s). The agent gets a slightly
# shorter internal MAX_HOURS guard so it can flush state before the hard kill.
export TASK_TIMEOUT="${TASK_TIMEOUT:-14400s}"   # 4h
export MAX_HOURS="${MAX_HOURS:-3.5}"

# --- Auth mode --------------------------------------------------------------
# Which Anthropic auth to forward: "subscription" (CLAUDE_CODE_OAUTH_TOKEN /
# ~/.claude/.credentials.json), "apikey" (ANTHROPIC_API_KEY), or "vertex"
# (no stored secret; the job's service account calls Claude via Vertex AI).
export CLAUDE_AUTH_MODE="${CLAUDE_AUTH_MODE:-subscription}"
# Which OpenAI/Codex auth to forward: "subscription" (~/.codex/auth.json) or
# "apikey" (OPENAI_API_KEY).
export CODEX_AUTH_MODE="${CODEX_AUTH_MODE:-subscription}"
