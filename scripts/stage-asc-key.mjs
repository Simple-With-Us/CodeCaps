// Stage the App Store Connect private key from Fleet-OPS Infisical prod /asc
// into a mode-600 file, and publish only the file's path.
//
// The key material never enters the environment.  It is read from the vault
// in this process, streamed over stdin into scripts/ios-stage-asc-key.sh, and
// written to a mode-600 file.  Only ASC_KEY_PATH crosses the step boundary,
// so no later step, no process listing and no environment dump can carry the
// key.
//
// ASC_KEY_ID and ASC_ISSUER_ID are identifiers rather than key material, and
// the ship and notarize steps need them, so they are published as ordinary
// environment entries.  The repository's stale ASC_* secrets are never read.
//
// Run: node scripts/stage-asc-key.mjs
import { spawn } from 'node:child_process';
import { appendFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  listSecretsRaw,
  loginUniversalAuth,
  maskValue,
  writeGithubEnvValue,
} from './infisical-fetch.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const STAGING_SCRIPT = join(here, 'ios-stage-asc-key.sh');
const SECRET_PATH = '/asc';

function fail(log, message) {
  log(`::error::${message}`);
  throw new Error(message);
}

/** The environment the staging script needs, and nothing else.
 *
 * The Infisical client credentials and the key itself stay out of the child
 * process, so the only thing the staging script can see is the key arriving
 * on its standard input. */
function childEnv(env) {
  const keep = ['PATH', 'GITHUB_ENV', 'RUNNER_TEMP', 'TMPDIR', 'ASC_STAGING_ROOT'];
  const out = {};
  for (const name of keep) {
    const value = env[name] ?? process.env[name];
    if (value !== undefined && value !== null && value !== '') out[name] = value;
  }
  return out;
}

export async function run({
  env = process.env,
  fetchImpl = fetch,
  log = (line) => console.log(line),
} = {}) {
  const siteUrl = String(env.INFISICAL_SITE_URL || 'https://app.infisical.com').replace(/\/+$/, '');
  const projectId = env.INFISICAL_PROJECT_ID || '';
  const environment = env.INFISICAL_ENVIRONMENT || 'prod';
  const secretPath = env.INFISICAL_SECRET_PATH || SECRET_PATH;
  const clientId = env.INFISICAL_CLIENT_ID || '';
  const clientSecret = env.INFISICAL_CLIENT_SECRET || '';

  if (!projectId || !clientId || !clientSecret) {
    fail(log, 'Missing the Infisical connection settings (INFISICAL_PROJECT_ID, INFISICAL_CLIENT_ID, INFISICAL_CLIENT_SECRET); the CI identity cannot reach Fleet-OPS prod /asc.');
  }

  const token = await loginUniversalAuth({ siteUrl, clientId, clientSecret, fetchImpl });
  const secrets = await listSecretsRaw({
    siteUrl, token, projectId, environment, secretPath, fetchImpl,
  });

  const keyId = secrets.get('ASC_KEY_ID') || '';
  const issuerId = secrets.get('ASC_ISSUER_ID') || '';
  const key = secrets.get('ASC_KEY_P8') || '';

  if (!key.trim()) {
    fail(log, 'Missing ASC_KEY_P8 in Fleet-OPS prod /asc; verify the CI identity has read access to Fleet-OPS prod /asc.');
  }
  if (!keyId.trim() || !issuerId.trim()) {
    fail(log, 'Missing ASC_KEY_ID or ASC_ISSUER_ID in Fleet-OPS prod /asc; verify the CI identity has read access to Fleet-OPS prod /asc.');
  }

  // Mask every line of the key, so the runner scrubs it from the log from
  // this point on even if something later prints it.
  maskValue(key, log);

  // Stream the key into the staging script over its standard input, so it
  // appears in no process listing and in no environment entry.  The script
  // writes the mode-600 file and publishes only its path.
  await new Promise((resolve, reject) => {
    const child = spawn('bash', [STAGING_SCRIPT], {
      stdio: ['pipe', 'inherit', 'inherit'],
      env: childEnv(env),
    });
    child.on('error', reject);
    child.on('close', (code) => {
      if (code === 0) resolve();
      else reject(new Error(`The ASC key staging script exited ${code}.`));
    });
    child.stdin.on('error', reject);
    child.stdin.end(key);
  });

  // The identifiers cross into the later steps.  The key never does.
  writeGithubEnvValue(env.GITHUB_ENV, 'ASC_KEY_ID', keyId);
  writeGithubEnvValue(env.GITHUB_ENV, 'ASC_ISSUER_ID', issuerId);
}

const invokedDirectly = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
if (invokedDirectly) {
  run().catch((err) => {
    console.log(`::error::${err.message}`);
    process.exitCode = 1;
  });
}
