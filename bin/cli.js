#!/usr/bin/env node
/*
 * cloudy-handoff CLI — a thin dispatcher over the bash implementation.
 *
 *   cloudy-handoff init                 provision GCP + install slash commands (one-time)
 *   cloudy-handoff "<task>"             hand off the current repo to the cloud
 *   cloudy-handoff --agent codex "…"    same, with a flag
 *   cloudy-handoff resume <id> "<task>" resume a session
 *   cloudy-handoff doctor               check prerequisites
 *   cloudy-handoff bootstrap [flags]    (re)provision only
 *   cloudy-handoff help
 *
 * The heavy lifting lives in scripts/*.sh; this shim just locates the package
 * and forwards arguments, exporting CLOUDY_HANDOFF_HOME so the scripts find
 * their libs, Dockerfile, and command templates regardless of cwd.
 */
'use strict';
const { spawnSync } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const ROOT = path.resolve(__dirname, '..');
const env = { ...process.env, CLOUDY_HANDOFF_HOME: ROOT };

function sh(script, args) {
  const r = spawnSync('bash', [path.join(ROOT, 'scripts', script), ...args], {
    stdio: 'inherit',
    env,
  });
  if (r.error) {
    console.error(`cloudy-handoff: failed to run ${script}: ${r.error.message}`);
    process.exit(1);
  }
  return r.status == null ? 1 : r.status;
}

// Copy the /handoff + /handoff-followup command templates into the user's
// Claude Code and Codex config dirs so the slash commands work everywhere.
function installCommands() {
  const src = path.join(ROOT, '.claude', 'commands');
  const targets = [
    path.join(os.homedir(), '.claude', 'commands'),
    path.join(os.homedir(), '.codex', 'prompts'),
  ];
  let files;
  try {
    files = fs.readdirSync(src).filter((f) => f.endsWith('.md'));
  } catch {
    return;
  }
  for (const dir of targets) {
    try {
      fs.mkdirSync(dir, { recursive: true });
      for (const f of files) fs.copyFileSync(path.join(src, f), path.join(dir, f));
      console.log(`✓ installed slash commands → ${dir}`);
    } catch (e) {
      console.error(`⚠ could not install commands to ${dir}: ${e.message}`);
    }
  }
}

function help() {
  console.log(`cloudy-handoff — offload a Claude Code / Codex session to a Cloud Run job

Usage:
  cloudy-handoff init [--project <id>] [--create-project <id>] [--region <r>]
                        Provision your GCP project and install the /handoff commands.
  cloudy-handoff "<task>"                 Hand off the current git repo to the cloud.
  cloudy-handoff --agent codex "<task>"   Use Codex instead of Claude.
  cloudy-handoff resume <session-id> ["<task>"]   Resume/queue onto a session.
  cloudy-handoff cancel <session-id>      Stop a running session.
  cloudy-handoff doctor                   Check prerequisites (gcloud, git, auth…).
  cloudy-handoff bootstrap [flags]        (Re)provision GCP resources only.
  cloudy-handoff help                     Show this help.

Prereqs: gcloud (authenticated), git, jq, curl. See ${ROOT}/README.md`);
}

const argv = process.argv.slice(2);
const cmd = argv[0];

switch (cmd) {
  case undefined:
  case 'help':
  case '-h':
  case '--help':
    help();
    break;
  case 'init':
    // Provision first; only install the slash commands if that succeeds.
    {
      const rc = sh('bootstrap.sh', argv.slice(1));
      if (rc === 0) installCommands();
      process.exit(rc);
    }
    break;
  case 'bootstrap':
    process.exit(sh('bootstrap.sh', argv.slice(1)));
    break;
  case 'resume': {
    // Accept both `resume <id> <task…>` and `resume "<id> <task…>"` (the latter
    // is what the /handoff-followup slash command sends as one quoted arg).
    const joined = argv.slice(1).join(' ').trim();
    const m = joined.match(/^(\S+)\s*([\s\S]*)$/);
    if (!m || !m[1]) {
      console.error('usage: cloudy-handoff resume <session-id> [task]');
      process.exit(1);
    }
    const a = ['--resume', m[1]];
    if (m[2]) a.push(m[2]);
    process.exit(sh('handoff.sh', a));
  }
  case 'cancel':
    if (!argv[1]) { console.error('usage: cloudy-handoff cancel <session-id>'); process.exit(1); }
    process.exit(sh('handoff.sh', ['--cancel', argv[1]]));
    break;
  case 'doctor':
    process.exit(sh('doctor.sh', argv.slice(1)));
    break;
  case 'install-commands':
    installCommands();
    break;
  default:
    // Anything else is a handoff: task text and/or flags (--agent, --dry-run…).
    process.exit(sh('handoff.sh', argv));
}
