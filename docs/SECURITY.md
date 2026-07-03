# Security & credentials

## Trust model: bring-your-own-GCP

cloudy-handoff is an **open-source tool, not a hosted service**. Every resource
runs in *your* GCP project, and your credentials travel exactly one path:

```
your laptop  →  YOUR Secret Manager  →  YOUR Cloud Run Job
```

No credential ever transits the repo author or any third party. Compared with a
SaaS, this is a *stronger* privacy posture — there is no external custodian of
your tokens. (When a managed service is built later, that's where multi-tenant
secret isolation, per-user KMS, and short-lived token exchange belong; none of
that is in scope here.)

## Subscription tokens: the ToS caveat

You chose to forward **local subscription tokens** so nothing re-authenticates
in the cloud. Be aware:

> Running a **consumer subscription** seat (Claude Pro/Max, ChatGPT/Codex)
> headless on cloud infrastructure is a **gray area** under the consumer terms
> and could, in principle, trigger abuse/anti-fraud flags on your account.

This is a deliberate tradeoff. Two cleaner alternatives are supported:

- **API keys** — `CLAUDE_AUTH_MODE=apikey` (`ANTHROPIC_API_KEY`) /
  `CODEX_AUTH_MODE=apikey` (`OPENAI_API_KEY`). Officially supported for headless
  use; billed at API rates, separate from your subscription.
- **Vertex AI (no stored Anthropic secret)** — `CLAUDE_AUTH_MODE=vertex`. Claude
  Code runs against Vertex AI and authenticates with the Job's **service
  account** (`CLAUDE_CODE_USE_VERTEX=1`). Nothing Anthropic-related is stored in
  Secret Manager; billing flows through GCP/Vertex. Codex has no GCP-native
  equivalent, so its token still uses Secret Manager.

For Claude subscription mode, prefer a **`claude setup-token`** token
(`CLAUDE_CODE_OAUTH_TOKEN`): it's the officially-sanctioned headless path and is
durable (~1 year). If it isn't set, the tool falls back to the short-lived token
in your local Claude credentials and warns you.

## How secrets are handled

- **Mounted, never inlined.** Secrets are attached to the Job via Secret Manager
  mounts. They are **never** passed with `--set-env-vars`, which would persist
  the plaintext value in the Job config and Cloud Audit Logs.
- **Placeholders.** `bootstrap.sh` seeds each secret with a `PLACEHOLDER`
  version so the Job definition is stable before your first handoff; the
  entrypoint unsets any credential env var still equal to `PLACEHOLDER`/empty.
- **Least privilege.** The runtime service account gets `secretAccessor` on the
  specific secrets only, bucket-scoped `storage.objectAdmin`, and
  `datastore.user`. No project-wide storage or secret admin.
- **Never logged.** Credential values are never echoed. Local reads go over the
  gcloud/TLS channel; the git token is written to `~/.git-credentials` inside the
  ephemeral container (chmod 600) and dies with it.
- **`.gitignore`** excludes `.cloudy-handoff.env`, `*.token`, `auth.json`, and
  `*.credentials.json` so local secrets can't be committed.

## Rotation & hygiene

- Rotate the `claude setup-token` (~1 yr) and the GitHub token before expiry;
  just re-run a handoff — creds are re-forwarded every time.
- Scope the GitHub token to `contents` + `pull_requests` write on the repos you
  actually hand off. A fine-grained PAT or a GitHub App installation token is
  preferable to a classic PAT.
- The agent runs with autonomy flags (`--dangerously-skip-permissions` /
  `--full-auto`) because the container is ephemeral and isolated. Treat each
  handoff branch as untrusted until you review its PR.
- Delete old GCS session blobs and prune Artifact Registry image tags
  periodically to avoid storage creep.
