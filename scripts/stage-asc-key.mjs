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
 *      which reads Fleet-OPS Infisical prod /asc through the fleet's own
 *      reader.  The getter is injected, so a test stubs the getter rather
 *      than a network endpoint.
 *
 * The private key never crosses a step boundary.  It is streamed over
 * stdin into scripts/ios-stage-asc-key.sh, which writes a mode-600 file
 * and publishes only its path.  The ASC_KEY_P8 entry is removed from the
 * job's environment file -- the bytes, not a blank assignment -- so that
 * no later step can read the key from the environment.  Only the two
 * identifiers are published, and they are masked before they are written.
 *
 * This script is the only thing in the release that reads a credential.  The
 * workflow installs the reader (scripts/install-release-secrets-tooling.sh
 * brings the Infisical CLI and the fleet's `fleet-secrets` onto the runner
 * and mints the access token they use) and this script calls the reader.
 * No workflow step asks the vault for a value, and no step's environment
 * carries the private key.
 *
 * Run: node scripts/stage-asc-key.mjs
 */
import { spawn, execFileSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { isUnresolvedReference, maskValue, writeGithubEnvValue } from './infisical-fetch.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const STAGING_SCRIPT = join(here, 'ios-stage-asc-key.sh');
const SECRET_FOLDER = '/asc';
const CREDENTIALS = ['ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_KEY_P8'];

/** The entries that must never survive in the job's environment file.  The
 *  private key is the only secret among them; the two identifiers are masked
 *  and are published deliberately, because the ship and notarize steps need
 *  them. */
const KEY_ENTRIES = new Set(['ASC_KEY_P8']);

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
 * (`NAME<<delimiter` ... `delimiter`) are understood, because a step that
 * writes a value that carries newlines writes the multiline form.
 *
 * A multiline block whose delimiter never arrives is malformed: the file was
 * truncated, or a step that was writing it was interrupted.  The name is
 * reported separately, because a value read out of such a block is not the
 * value that was written.  The body that did arrive is kept as the file's
 * candidate for that name, so a malformed entry is still rejected on its own
 * terms instead of being silently passed over. */
function readEnvironmentFile(path) {
  const values = new Map();
  const malformed = new Set();
  if (!path || !existsSync(path)) return { values, malformed };
  const lines = readFileSync(path, 'utf8').split(/\r?\n/);
  for (let i = 0; i < lines.length; i += 1) {
    const heredoc = /^([A-Za-z_][A-Za-z0-9_]*)<<(.+)$/.exec(lines[i]);
    if (heredoc) {
      const body = [];
      let j = i + 1;
      while (j < lines.length && lines[j] !== heredoc[2]) {
        body.push(lines[j]);
        j += 1;
      }
      if (j >= lines.length) {
        malformed.add(heredoc[1]);
        values.set(heredoc[1], body.join('\n'));
        i = lines.length;
        continue;
      }
      values.set(heredoc[1], body.join('\n'));
      i = j;
      continue;
    }
    const single = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(lines[i]);
    if (single) values.set(single[1], single[2]);
  }
  return { values, malformed };
}

/**
 * Remove every entry for `names` from the job's environment file.
 *
 * The runner imports this file into the environment of every later step in
 * the job, including the steps that run `if: always()`.  A key-bearing line
 * that stays in the file is a key that reaches those steps.  Writing a blank
 * assignment for the same name does not help: the earlier bytes are still in
 * the file, and the runner reads the file line by line.  The entry itself is
 * removed instead, in the single-line form and in the heredoc form a step
 * writes for a value that carries newlines.
 *
 * A heredoc block whose delimiter never arrives is dropped to the end of the
 * file.  The end of the key material cannot be known in that case, so the
 * only safe reading is that everything after the header belongs to it.
 */
export function removeEnvironmentEntries(path, names) {
  if (!path || !names || names.size === 0 || !existsSync(path)) return false;
  const lines = readFileSync(path, 'utf8').split(/\r?\n/);
  const kept = [];
  let removed = false;
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    const heredoc = /^([A-Za-z_][A-Za-z0-9_]*)<<(.+)$/.exec(line);
    if (heredoc) {
      const body = [];
      let j = i + 1;
      while (j < lines.length && lines[j] !== heredoc[2]) {
        body.push(lines[j]);
        j += 1;
      }
      const closed = j < lines.length;
      if (names.has(heredoc[1])) {
        removed = true;
        i = closed ? j + 1 : lines.length;
        continue;
      }
      kept.push(line);
      for (const entry of body) kept.push(entry);
      if (closed) kept.push(lines[j]);
      i = closed ? j + 1 : lines.length;
      continue;
    }
    const single = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(line);
    if (single && names.has(single[1])) {
      removed = true;
      i += 1;
      continue;
    }
    kept.push(line);
    i += 1;
  }
  if (!removed) return false;
  writeFileSync(path, kept.join('\n'));
  return true;
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
function checkCredential(log, name, value, malformed = false) {
  if (malformed) {
    fail(log, `${name} is malformed in the job environment file: its multiline block is not terminated, so the file was truncated or a step that was writing it was interrupted; verify the CI identity can read Fleet-OPS prod /asc.`);
  }
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
  stagingScript = STAGING_SCRIPT,
} = {}) {
  const envPath = env.GITHUB_ENV;

  /** The private key must not survive in the job's environment file, whatever
   *  happens below.  The runner imports that file into the environment of
   *  every later step in the job, including the steps that run
   *  `if: always()`, so a key-bearing entry that stays in the file is a key
   *  that reaches them.  The entry is removed, bytes and all; a blank
   *  assignment would leave the earlier bytes in the file for the runner to
   *  read. */
  const sanitize = () => {
    removeEnvironmentEntries(envPath, KEY_ENTRIES);
    if (env.ASC_KEY_P8 !== undefined) delete env.ASC_KEY_P8;
  };

  /** An interruption is a failure path like any other: the key is removed
   *  before the process leaves.  The default handling of these signals would
   *  leave the process without running the cleanup below. */
  const onSignal = () => {
    sanitize();
    process.exit(1);
  };
  process.on('SIGTERM', onSignal);
  process.on('SIGINT', onSignal);

  try {
    // The values are read before the file is sanitized, and they are held in
    // memory only: once the read is done, the key leaves the file.
    const { values: fromFile, malformed } = readEnvironmentFile(envPath);
    const fromProcess = new Map(CREDENTIALS.map((name) => [name, env[name]]));
    sanitize();

    /** Environment first, then the approved fallback: `fleet-secrets get`,
     *  captured and never echoed.  The result says where the value came
     *  from, because the verdict on a malformed job environment file only
     *  belongs to a value that file actually supplied. */
    const resolve = async (name) => {
      const named = fromProcess.get(name);
      if (typeof named === 'string' && named.trim() !== '') return { value: named, fromFile: false };
      const written = fromFile.get(name);
      if (typeof written === 'string' && written.trim() !== '') return { value: written, fromFile: true };
      const fetched = await getSecret(name, SECRET_FOLDER);
      return { value: typeof fetched === 'string' ? fetched : '', fromFile: false };
    };

    const keyIdSrc = await resolve('ASC_KEY_ID');
    const issuerIdSrc = await resolve('ASC_ISSUER_ID');
    const keySrc = await resolve('ASC_KEY_P8');
    const keyId = checkCredential(log, 'ASC_KEY_ID', keyIdSrc.value, keyIdSrc.fromFile && malformed.has('ASC_KEY_ID'));
    const issuerId = checkCredential(log, 'ASC_ISSUER_ID', issuerIdSrc.value, issuerIdSrc.fromFile && malformed.has('ASC_ISSUER_ID'));
    const key = checkCredential(log, 'ASC_KEY_P8', keySrc.value, keySrc.fromFile && malformed.has('ASC_KEY_P8'));

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
      const child = spawn('bash', [stagingScript], {
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
    // does not: its entry was removed from the environment file when the
    // values were read, so a later step sees no value for it at all.
    writeGithubEnvValue(envPath, 'ASC_KEY_ID', keyId);
    writeGithubEnvValue(envPath, 'ASC_ISSUER_ID', issuerId);

    log(`::notice::Staged the ASC private key from Fleet-OPS prod ${SECRET_FOLDER}; only ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID cross into the later steps.`);
  } finally {
    process.removeListener('SIGTERM', onSignal);
    process.removeListener('SIGINT', onSignal);
    // Every failure path lands here: a missing credential, a rejected
    // reference, malformed multiline data, a staging failure, an
    // interruption.  The key leaves the environment file in all of them.
    sanitize();
  }
}

const invokedDirectly = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
if (invokedDirectly) {
  run().catch((err) => {
    console.error(err instanceof Error ? err.message : String(err));
    process.exitCode = 1;
  });
}
