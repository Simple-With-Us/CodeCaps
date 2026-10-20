// Stage the ASC private key from the environment into the protected key-file
// handoff, and take it back out of the environment.
//
// The key itself is fetched by the infisical-secrets composite action, which
// is this repository's approved way to read a value out of the vault: it
// masks every line of every value and never prints one.  This script does
// not talk to the vault itself.
//
// The key is multiline, so it must not stay in the environment.  The key is
// streamed into scripts/ios-stage-asc-key.sh, which writes the mode-600 file
// and publishes only its path, and the environment variable is then blanked
// so that no later step carries the key.
//
// The value never reaches a command line: it is written to the staging
// script's standard input, so it appears in no process arguments.
//
// Run: node scripts/stage-asc-key.mjs
import { spawn } from 'node:child_process';
import { appendFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const STAGING_SCRIPT = join(here, 'ios-stage-asc-key.sh');
const SECRET_NAME = 'ASC_KEY_P8';

function fail(log, message) {
  log(`::error::${message}`);
  throw new Error(message);
}

/** Hand the key in the environment to the staging script and blank it.
 *
 * The key is written to the staging script's standard input rather than to
 * its arguments, so it appears in no process listing. */
export async function run({ env = process.env, log = (line) => console.log(line) } = {}) {
  const value = env[SECRET_NAME];
  if (value === undefined || value === null || String(value).trim() === '') {
    fail(log, `Missing ASC key material in Fleet-OPS prod /asc; verify the CI identity has read access to Fleet-OPS prod /asc.`);
  }

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

  // Take the key back out of the environment.  The runner applies these
  // entries in order, so the empty value is the one later steps see.
  if (env.GITHUB_ENV) {
    appendFileSync(env.GITHUB_ENV, `${SECRET_NAME}=\n`);
  }
}

const invokedDirectly = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
if (invokedDirectly) {
  run().catch((err) => {
    console.log(`::error::${err.message}`);
    process.exitCode = 1;
  });
}
