// Fetch the ASC private key from Infisical and hand it to the protected
// key-file handoff.
//
// The key is multiline, so it must never become an environment variable.
// This script uses the same safe helpers the composite action uses --
// universal-auth login, one secrets list for the whole path, every line of
// every value masked -- and then streams the key into
// scripts/ios-stage-asc-key.sh, which writes the mode-600 file and publishes
// only its path.
//
// The bare `infisical secrets get` CLI is not used anywhere in this path.
// The CLI is macOS-only to install, and it prints the value to stdout, which
// is exactly what a secret must never do.
//
// Run: node scripts/infisical-fetch-asc-key.mjs
import { spawn } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { listSecretsRaw, loginUniversalAuth, maskValue } from './infisical-fetch.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const STAGING_SCRIPT = join(here, 'ios-stage-asc-key.sh');
const SECRET_NAME = 'ASC_KEY_P8';

function fail(log, message) {
  log(`::error::${message}`);
  throw new Error(message);
}

/** Fetch ASC_KEY_P8 and stream it into the staging script.
 *
 * The value is masked before it is handed over, so it cannot reach the log
 * even if the handoff fails.  It is never written to GITHUB_ENV: the
 * staging script publishes only the path of the file it wrote. */
export async function run({ env = process.env, fetchImpl = fetch, log = (line) => console.log(line) } = {}) {
  const projectId = env.INFISICAL_PROJECT_ID;
  const clientId = env.INFISICAL_CLIENT_ID;
  const clientSecret = env.INFISICAL_CLIENT_SECRET;
  const siteUrl = env.INFISICAL_SITE_URL || 'https://app.infisical.com';
  const environment = env.INFISICAL_ENVIRONMENT || 'prod';
  const secretPath = env.INFISICAL_SECRET_PATH || '/asc';

  if (!projectId) {
    fail(log, 'INFISICAL_PROJECT_ID is required.');
  }
  if (!clientId || !clientSecret) {
    fail(log, 'Missing Infisical machine identity.  Set INFISICAL_UNIVERSAL_AUTH_CLIENT_ID/SECRET (fallback INFISICAL_CLIENT_ID/SECRET) on the org or repo.');
  }

  const token = await loginUniversalAuth({ siteUrl, clientId, clientSecret, fetchImpl });
  maskValue(token, log);

  const values = await listSecretsRaw({ siteUrl, token, projectId, environment, secretPath, fetchImpl });
  const value = values.get(SECRET_NAME);
  if (value === undefined || value === null || String(value).trim() === '') {
    fail(log, `Missing ${SECRET_NAME} in Fleet-OPS prod ${secretPath}; verify the CI identity has read access to Fleet-OPS prod ${secretPath}.`);
  }
  maskValue(value, log);

  // The value crosses a pipe and nothing else: not the environment, not the
  // command line, not a file the workflow can read.  The staging script
  // needs GITHUB_ENV and its staging root, so the caller's environment is
  // passed through to it unchanged.
  await new Promise((resolve, reject) => {
    const child = spawn('bash', [STAGING_SCRIPT], {
      stdio: ['pipe', 'inherit', 'inherit'],
      env: { ...process.env, ...env },
    });
    child.on('error', reject);
    child.on('close', (code) => {
      if (code === 0) resolve();
      else reject(new Error(`The ASC key staging script exited ${code}.`));
    });
    child.stdin.on('error', reject);
    child.stdin.end(value);
  });
}

const invokedDirectly = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
if (invokedDirectly) {
  run().catch((err) => {
    console.log(`::error::${err.message}`);
    process.exitCode = 1;
  });
}
