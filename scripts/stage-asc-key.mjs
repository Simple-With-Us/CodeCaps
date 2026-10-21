#!/usr/bin/env node
/**
 * Stage the App Store Connect private key into the protected key-file
 * handoff, and publish only what the later steps need.
 *
 * Each of ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 is resolved in this
 * order:
 *
 *   1. the environment.  process.env comes first, then the job's
 *      environment file -- the file the runner reads the $GITHUB_ENV
 *      entries from.  A named variable always wins, so the job's own
 *      environment is the first place a credential is looked up.
 *   2. the approved fallback: `fleet-secrets get <name> --path /asc`,
 *      which reads Fleet-OPS Infisical prod /asc on a developer machine.
 *      The getter is injected, so a test stubs the getter rather than a
 *      network endpoint.
 *
 * The private key never crosses a step boundary.  It is streamed over
 * stdin into scripts/ios-stage-asc-key.sh, which writes a mode-600 file
 * and publishes only its path, and the ASC_KEY_P8 entry is then blanked so
 * that no later step can read the key from the environment.  Only the two
 * identifiers are published, and they are masked before they are written.
 *
 * This script does not talk to the vault.  The approved loader
 * (scripts/infisical-fetch.mjs, byte-identical to the BotFleet copy, the
 * script the infisical-secrets composite action runs) does that, and the
 * values it exports are read here through the environment.  Keeping the
 * retrieval in one place is what lets the key stay out of every step's
 * environment: the loader and this script run in the same step, so the
 * key never becomes an environment variable of any step.
 *
 * Run: node scripts/stage-asc-key.mjs
 */
import { spawn, execFileSync } from 'node:child_process';
import { appendFileSync, existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { isUnresolvedReference, maskValue, writeGithubEnvValue } from './infisical-fetch.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const STAGING_SCRIPT = join(here, 'ios-stage-asc-key.sh');
const SECRET_FOLDER = '/asc';
const CREDENTIALS = ['ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_KEY_P8'];

/** The environment the staging script needs, and nothing else.  Neither the
 * key nor the vault credentials reach the child process, so it appears in
 * no process listing and in no environment entry. */
function childEnv(env) {
  const keep = ['PATH', 'GITHUB_ENV', 'RUNNER_TEMP', 'TMPDIR', 'ASC_STAGING_ROOT'];
  const out = {};
  for (const name of keep) {
    const value = env[name] ?? process.env[name];
    if (value !== undefined && value !== null && value !== '') out[name] = value;
  }
  return out;
}

/** Read the job's environment file: the entries a step wrote through
 * $GITHUB_ENV, which the runner applies to the steps that follow.  Both
 * the single-line form (`NAME=value`) and the multiline form
 * (`NAME<<delimiter` ... `delimiter`) are understood, because the approved
 * loader writes the multiline form for a value that carries newlines. */
function readEnvironmentFile(path) {
  const values = new Map();
  if (!path || !existsSync(path)) return values;
  const lines = readFileSync(path, 'utf8').split(/\r?\n/);
  for (let i = 0; i < lines.length; i += 1) {
    const heredoc = /^([A-Za-z_][A-Za-z0-9_]*)<<(.+)$/.exec(lines[i]);
    if (heredoc) {
      const body = [];
      i += 1;
      while (i < lines.length && lines[i] !== heredoc[2]) {
        body.push(lines[i]);
        i += 1;
      }
      values.set(heredoc[1], body.join('\n'));
      continue;
    }
    const single = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(lines[i]);
    if (single) values.set(single[1], single[2]);
  }
  return values;
}

/** The approved fallback: `fleet-secrets get <name> --path <folder>` reads
 * Fleet-OPS Infisical prod /asc.  The value is captured, never echoed, and
 * the failure is an empty string rather than an exception, so a missing
 * tool reads as a missing credential. */
export function fleetSecretsGet(name, folder) {
  const localBin = join(homedir(), '.local', 'bin', 'fleet-secrets');
  const bin = process.env.FLEET_SECRETS || (existsSync(localBin) ? localBin : 'fleet-secrets');
  try {
    return execFileSync(bin, ['get', name, '--path', folder], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).replace(/\n$/, '');
  } catch {
    return '';
  }
}

function fail(log, message) {
  log(`::error::${message}`);
  throw new Error(message);
}

/**
 * The schema every credential value has to satisfy before it is used.  It
 * is checked once, where the value enters the script, so a malformed value
 * can never reach a lookup, a log line or the key file.
 *
 * A value that is still a bare Infisical reference such as
 * ${prod.some-folder.NAME} is rejected: the server did not expand it,
 * because the target is missing or the reading identity cannot read the
 * referenced folder.  Staging it would hand a later tool the reference
 * string as if it were the credential, and the failure would surface much
 * later as an opaque parse error.
 */
function checkCredential(log, name, value) {
  if (typeof value !== 'string' || value.trim() === '') {
    fail(log, `Missing ${name} in Fleet-OPS prod /asc; verify the CI identity has read access to Fleet-OPS prod /asc.`);
  }
  if (isUnresolvedReference(value)) {
    fail(log, `${name} is still an unresolved Infisical secret reference in Fleet-OPS prod /asc; check the target exists and the CI identity can read the referenced folder.`);
  }
  return value;
}

export async function run({
  env = process.env,
  getSecret = fleetSecretsGet,
  log = (line) => console.log(line),
} = {}) {
  const fromFile = readEnvironmentFile(env.GITHUB_ENV);

  /** Environment first, then the approved fallback. */
  const resolve = async (name) => {
    const named = env[name];
    if (typeof named === 'string' && named.trim() !== '') return named;
    const written = fromFile.get(name);
    if (typeof written === 'string' && written.trim() !== '') return written;
    const fetched = await getSecret(name, SECRET_FOLDER);
    return typeof fetched === 'string' ? fetched : '';
  };

  const keyId = checkCredential(log, 'ASC_KEY_ID', await resolve('ASC_KEY_ID'));
  const issuerId = checkCredential(log, 'ASC_ISSUER_ID', await resolve('ASC_ISSUER_ID'));
  const key = checkCredential(log, 'ASC_KEY_P8', await resolve('ASC_KEY_P8'));

  // The identifiers cross into the later steps, so they are masked first: a
  // tool that echoes them leaves nothing behind in the public job log.  The
  // key is not masked, because it never reaches the log at all -- it is
  // written straight to the mode-600 file below.
  maskValue(keyId, log);
  maskValue(issuerId, log);

  // The key is streamed over stdin, so it appears in no process listing and
  // in no environment entry.  The staging script writes the mode-600 file
  // and publishes only its path.
  await new Promise((resolvePromise, rejectPromise) => {
    const child = spawn('bash', [STAGING_SCRIPT], {
      stdio: ['pipe', 'inherit', 'inherit'],
      env: childEnv(env),
    });
    child.on('error', rejectPromise);
    child.on('close', (code) => {
      if (code === 0) resolvePromise();
      else rejectPromise(new Error(`The ASC key staging script exited ${code}.`));
    });
    child.stdin.on('error', rejectPromise);
    child.stdin.end(key);
  });

  // Only the identifiers and the path cross into the later steps.  The key
  // does not: the entry is blanked, and the runner applies the entries in
  // order, so a later step sees an empty value rather than the key.
  writeGithubEnvValue(env.GITHUB_ENV, 'ASC_KEY_ID', keyId);
  writeGithubEnvValue(env.GITHUB_ENV, 'ASC_ISSUER_ID', issuerId);
  if (env.GITHUB_ENV) appendFileSync(env.GITHUB_ENV, 'ASC_KEY_P8=\n');

  log(`::notice::Staged the ASC private key from Fleet-OPS prod ${SECRET_FOLDER}; only ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID cross into the later steps.`);
}

const invokedDirectly = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
if (invokedDirectly) {
  run().catch((err) => {
    console.error(err instanceof Error ? err.message : String(err));
    process.exitCode = 1;
  });
}
