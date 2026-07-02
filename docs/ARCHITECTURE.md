# Architecture

## Why Cloud Run Jobs

The core requirement is "run a coding agent continuously until the task is done,
without babysitting a VM." Cloud Run **Jobs** fit this better than the
alternatives:

| Option | Fit |
|---|---|
| **Cloud Run Job** ✅ | Runs to completion, task timeout up to **168h**, scales to zero (no idle cost), no HTTP server to write. Exactly "run until done." |
| Cloud Run Service | Request timeout caps at 60 min; keeping a long agent alive across requests is fragile. Right for a *control plane*, not the worker. |
| GCE / GKE VM | Always-on cost, ops burden, and explicitly ruled out ("no VMs"). |
| Cloudflare Workers | Can't run arbitrary binaries / Chromium / long CPU. Out. |

## Components (all in the user's own GCP project)

- **Cloud Run Job `cloudy-handoff`** — the worker. One execution per handoff (or
  follow-up). 2 vCPU / 4 GiB by default; sized in `.cloudy-handoff.env`.
- **Artifact Registry** — holds the agent-runtime image.
- **Secret Manager** — the agent token + a GitHub token + Codex `auth.json`.
  Mounted into the Job; the runtime SA has `secretAccessor` on those secrets
  only.
- **GCS bucket** — bulky blobs per session: the captured uncommitted patch,
  the transcript tarball, and run logs.
- **Firestore (native)** — the `sessions/<id>` registry: status, agent, repo,
  base branch/sha, branch, PR url, `claudeSessionId`, timestamps.
- **A least-privilege runtime service account** — `datastore.user`,
  bucket-scoped `storage.objectAdmin`, and per-secret `secretAccessor`. Nothing
  project-wide beyond Firestore (which has no per-database IAM).

## State model

Three stores, each for what it's best at:

- **Git branch `handoff/<id>`** — source of truth for *code changes*. Reviewable,
  PR-able, and the natural unit a follow-up builds on.
- **Firestore `sessions/<id>`** — small/hot state. Cheap, single-digit-ms reads,
  and real-time listeners a future control-plane / mobile UI can subscribe to.
- **GCS `sessions/<id>/`** — bulky blobs (`transcript.tgz`, `uncommitted.patch`,
  `untracked.tar.gz`, `run-*.log`). These exceed Firestore's 1 MiB/doc limit and
  cost ~9× less per GB in GCS.

Resume speed is dominated by container cold start + `git clone` + agent init
(seconds), so the GCS-vs-Firestore read difference (~200 ms) is irrelevant — the
split is about cost and future fit, not latency.

## Lifecycle (docker/entrypoint.sh)

1. **Auth setup** — unset placeholder creds; configure the git credential helper
   from `GIT_TOKEN`; copy the Codex `auth.json` mount into `~/.codex`; enable
   Vertex mode if selected.
2. **Restore** — `git clone`; then either create `handoff/<id>` from the base and
   re-apply the captured patch + untracked files (fresh run), or check out the
   existing branch and restore the transcript tarball (resume).
3. **Run** — `claude -p …` or `codex exec …` to completion, under a `MAX_HOURS`
   wall-clock guard (below the Job's hard task timeout so state can flush).
4. **Persist** — commit, push `handoff/<id>`, open/find the PR; upload the
   transcript + run log to GCS; write final status + PR url + `claudeSessionId`
   to Firestore.

### Resume detail

The agent runs in a constant working path (`/workspace/repo`), so Claude's
project-hash under `~/.claude/projects/<hash>` is stable across executions. We
record `claudeSessionId` (the transcript filename) in Firestore on the first run;
a follow-up restores `transcript.tgz` and calls `claude --resume <sessionId>`,
so the agent keeps full context.

## Credentials path

Laptop → **your** Secret Manager → **your** Job. Nothing transits a third party.
Secrets are mounted (never passed as `--set-env-vars`, which would expose them in
Job config and audit logs). See [SECURITY.md](SECURITY.md).

## Roadmap (additive — reuses this worker unchanged)

The future — login, "Aino joins a meeting," a knowledge store — is a
**control-plane + workers** pattern, still all-serverless / no-VM:

- **Control-plane Cloud Run *Service*** (scale-to-zero): Firebase Auth login,
  web/mobile UI + REST, launches and tracks Jobs. This is where a future managed
  SaaS would add multi-tenant secret isolation.
- **Meeting worker = another Job.** It dials *outward* into the meeting (WebRTC/
  websocket), stays for its duration (168h cap is ample), writes notes to
  Firestore, and exits. Mid-session control ("mute," "summarize now," mobile
  commands) arrives via a **Firestore / Pub-Sub command channel the Job polls** —
  not inbound HTTP.
- **Firestore** doubles as the knowledge store; add Vertex AI Vector Search or
  pgvector on Cloud SQL only if/when semantic search is needed.

Nothing in the current design is thrown away to get there: the Firestore session
registry and the stateless, parameterized worker are exactly the shapes those
layers consume.
