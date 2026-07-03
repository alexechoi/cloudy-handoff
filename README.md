# cloudy-handoff

Hand off any **Claude Code** or **Codex** session into a **Google Cloud Run
job** that runs autonomously until the task is done — then commits its work,
pushes a `handoff/<id>` branch, and opens a PR. Follow-up runs resume the same
session with full context.

```
/handoff "refactor the uploader to stream and add retry + tests"
```

You keep working locally; the task finishes in the cloud.

- **Serverless, no VMs.** Cloud Run Jobs scale to zero — you pay only while a
  task runs (~$0.21/hr at 2 vCPU / 4 GiB; ~25h/month free).
- **Runs until done.** Job task timeout up to 168h. No request limits, no
  keep-alive hacks.
- **Bring-your-own-GCP.** Everything runs in *your* project. Your Claude / Codex
  / git credentials go laptop → *your* Secret Manager → *your* Job, and never
  touch anyone else. This is an open-source tool, **not** a hosted service.
- **Works like your machine.** The image ships git, ripgrep, build tools, the
  gcloud CLI, and a headless **Chromium** (via Playwright) so the agent can
  browse and build much as it does locally.

> **Heads up:** forwarding a *consumer subscription* token (Claude Pro/Max,
> ChatGPT/Codex) to run headless in the cloud is a ToS gray area. API-key and
> Vertex-AI modes are supported as cleaner alternatives — see
> [docs/SECURITY.md](docs/SECURITY.md).

---

## How it works

```
Local (gcloud authed)
  /handoff "<task>"  →  scripts/handoff.sh
     ├─ capture repo state (branch/sha + uncommitted diff + untracked → GCS)
     ├─ forward creds → your Secret Manager (agent token + GitHub token)
     ├─ write session doc → Firestore
     └─ gcloud run jobs execute cloudy-handoff --update-env-vars …

Cloud Run Job "cloudy-handoff"  (2 vCPU / 4 GiB)
     restore repo + uncommitted work (or resume the transcript)
     run the agent to completion  (claude -p … / codex exec …)
     commit → push handoff/<id> → open PR
     persist transcript + logs → GCS; status → Firestore
```

State lives in three places, each for what it's best at: the **git branch** is
the source of truth for code; **Firestore** holds small/hot session state
(status, PR url, `claudeSessionId`); **GCS** holds bulky blobs (the transcript
tarball, the captured patch, run logs). See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

---

## Prerequisites

- A **GCP project** with billing enabled, and the [`gcloud`
  CLI](https://cloud.google.com/sdk/docs/install) authenticated:
  ```bash
  gcloud auth login
  gcloud config set project YOUR_PROJECT_ID
  ```
- Local credentials for whichever agent you use:
  - **Claude** — a subscription token (`claude setup-token`, recommended: it's a
    durable 1-year token), or `ANTHROPIC_API_KEY`.
  - **Codex** — `~/.codex/auth.json` (run `codex login`), or `OPENAI_API_KEY`.
- A **GitHub token** with `contents` + `pull_requests` write (so the job can
  push and open PRs). Picked up automatically from `gh auth token`,
  `~/.git-credentials`, or `$GITHUB_TOKEN`.

## Setup (once per project)

```bash
git clone https://github.com/alexechoi/cloudy-handoff && cd cloudy-handoff
cp deploy/config.example.sh .cloudy-handoff.env   # optional; sensible defaults otherwise
./scripts/bootstrap.sh        # provisions everything; add --build to force an image rebuild
./scripts/install.sh          # puts `cloudy-handoff` on PATH + installs the slash commands
```

`bootstrap.sh` is idempotent — it enables the required APIs and creates a
least-privilege service account, a GCS bucket, a Firestore (native) database, an
Artifact Registry repo, the credential secrets, and the Cloud Run Job. Re-run it
anytime (e.g. after `git pull` to rebuild the image with `--build`).

## Usage

From inside any git repo:

```bash
/handoff "add pagination to the search endpoint and cover it with tests"
/handoff --agent codex "port scripts/parse.py to Rust"
/handoff-followup 20260702-1a2b3c-9f "now also update the CHANGELOG"
```

Or call the CLI directly: `cloudy-handoff "…"`.

**Flags** (`cloudy-handoff --help`):

| Flag | Meaning |
|---|---|
| `--agent claude\|codex` | Which agent to run (default `claude`). |
| `--resume <id> [text]` | Resume a session; empty text just continues. |
| `--no-pr` | Push the branch but don't open a PR. |
| `--dry-run` | Print the exact launch command; spend nothing. |

**Watch it:**
```bash
gcloud run jobs executions list --job cloudy-handoff --region us-central1
gcloud beta run jobs logs tail cloudy-handoff --region us-central1
```
When it finishes, the PR link is on the Firestore `sessions/<id>` doc (and in the
`done` log line).

## Auth modes

Set in `.cloudy-handoff.env`:

| Var | Values | Notes |
|---|---|---|
| `CLAUDE_AUTH_MODE` | `subscription` (default) · `apikey` · `vertex` | `vertex` stores **no** Anthropic secret — the job calls Claude via Vertex AI using its service account (bills through GCP). |
| `CODEX_AUTH_MODE` | `subscription` (default) · `apikey` | `subscription` forwards `~/.codex/auth.json`. |

Credentials are re-forwarded on every handoff, so rotated/refreshed tokens stay
current.

## Cost

Cloud Run Jobs bill only while running. At 2 vCPU / 4 GiB that's ≈ **$0.21/hr**,
and the monthly free tier (~180k vCPU-seconds) covers ~25h of runtime. Moderate
use lands around **$18–20/month** (compute-dominated); rare use is ~$2/month.
Secret Manager, Artifact Registry, GCS and Firestore are pennies at this volume.
Cheaper than an always-on VM unless you run agents nearly continuously.

## What this is *not* (yet)

Real-time "type into the running session from my phone" is **not** possible on
Cloud Run Jobs (no inbound stdin/HTTP). The model here is **autonomous run →
PR/logs → follow-up run**. A control-plane service (login, web/mobile UI), a
"join my meeting" worker, and a knowledge store are planned as an *additive*
layer that reuses this worker — see the roadmap in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Repo layout

```
scripts/bootstrap.sh     one-time GCP provisioning (idempotent)
scripts/handoff.sh       local trigger
scripts/install.sh       PATH shim + slash-command install
scripts/lib/             gcp / creds / repo-state helpers
docker/Dockerfile        agent-runtime image (Node + CLIs + Chromium + gcloud)
docker/entrypoint.sh     in-cloud lifecycle
.claude/commands/        /handoff and /handoff-followup
deploy/                  config example, job env docs, Cloud Build
docs/                    ARCHITECTURE.md, SECURITY.md
```

## License

Apache 2.0 — see [LICENSE](LICENSE).
