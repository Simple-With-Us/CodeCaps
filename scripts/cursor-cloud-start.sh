#!/usr/bin/env bash
# Cursor cloud agent start for CodeCaps.
#
# Runs on every agent boot.  When the dashboard has injected
# INFISICAL_CLIENT_ID and INFISICAL_CLIENT_SECRET, logs into Infisical
# universal auth and exports the dev-env secret map for this repo to a
# 0600 file at $HOME/.cursor-cloud-env/codecaps.env, plus a tiny
# codecaps.source.sh that future shells can `source` without printing.
#
# If the dashboard secrets are missing, prints the missing NAMES (never
# values) and exits 0 so the agent boots cleanly.  Never prints a secret
# value at any point.
#
# Uses the same universal-auth + raw-secrets API as scripts/infisical-fetch.mjs
# (which the mac-release workflow uses for GITHUB_ENV), but the dotenv
# output here is the form a Linux non-Apple script actually needs.
set -euo pipefail

REPO_NAME="codecaps"
ENV_DIR="${HOME}/.cursor-cloud-env"
ENV_FILE="${ENV_DIR}/${REPO_NAME}.env"
SOURCE_FILE="${ENV_DIR}/${REPO_NAME}.source.sh"
INFISICAL_ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.cursor/infisical.env"

# 1.  Load the committed, non-secret Infisical coordinates.
if [[ -f "${INFISICAL_ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "${INFISICAL_ENV_FILE}"
  set +a
fi

# 2.  Require the dashboard-injected credentials by NAME only.
MISSING=()
[[ -z "${INFISICAL_CLIENT_ID:-}" ]]     && MISSING+=("INFISICAL_CLIENT_ID")
[[ -z "${INFISICAL_CLIENT_SECRET:-}" ]] && MISSING+=("INFISICAL_CLIENT_SECRET")
if (( ${#MISSING[@]} > 0 )); then
  echo "CodeCaps: skipping Infisical export.  Add the following names to the Cursor dashboard secrets: ${MISSING[*]}"
  exit 0
fi

# 3.  Fetch the dev-env secrets via the same API path as
#     scripts/infisical-fetch.mjs (loginUniversalAuth + listSecretsRaw),
#     then emit a dotenv file on stdout.  The script does not echo values
#     and does not log the response body.  Stderr only carries status.
mkdir -p "${ENV_DIR}"
chmod 0700 "${ENV_DIR}"

OUT="$(mktemp)"
trap 'rm -f "${OUT}"' EXIT

if INFISICAL_SITE_URL="${INFISICAL_DOMAIN:-https://app.infisical.com}" \
   INFISICAL_PROJECT_ID="${INFISICAL_PROJECT_ID:-}" \
   INFISICAL_ENVIRONMENT="${INFISICAL_ENV:-dev}" \
   INFISICAL_SECRET_PATH="${INFISICAL_SECRET_PATH:-/}" \
   node -e '
     const site = String(process.env.INFISICAL_SITE_URL || "").replace(/\/+$/, "");
     const projectId = process.env.INFISICAL_PROJECT_ID || "";
     const env = process.env.INFISICAL_ENVIRONMENT || "dev";
     const path = process.env.INFISICAL_SECRET_PATH || "/";
     const cid = process.env.INFISICAL_CLIENT_ID || "";
     const cs  = process.env.INFISICAL_CLIENT_SECRET || "";
     const log = (m) => process.stderr.write(m + "\n");
     if (!site || !projectId || !cid || !cs) { log("CodeCaps: Infisical config incomplete; skipping."); process.exit(0); }
     (async () => {
       try {
         const lr = await fetch(site + "/api/v1/auth/universal-auth/login", {
           method: "POST", headers: { "content-type": "application/json" },
           body: JSON.stringify({ clientId: cid, clientSecret: cs }),
           signal: AbortSignal.timeout(30000),
         });
         if (!lr.ok) { log("CodeCaps: Infisical login failed (HTTP " + lr.status + ")."); process.exit(0); }
         const lb = await lr.json();
         const token = lb && lb.accessToken;
         if (!token) { log("CodeCaps: Infisical login returned no accessToken."); process.exit(0); }
         const qs = new URLSearchParams({
           workspaceId: projectId, environment: env, secretPath: path,
           viewSecretValue: "true", expandSecretReferences: "false", include_imports: "false",
         });
         const sr = await fetch(site + "/api/v3/secrets/raw?" + qs.toString(), {
           method: "GET", headers: { authorization: "Bearer " + token },
           signal: AbortSignal.timeout(30000),
         });
         if (!sr.ok) { log("CodeCaps: Infisical list failed (HTTP " + sr.status + ")."); process.exit(0); }
         const sb = await sr.json();
         const seen = new Set();
         for (const s of (sb && sb.secrets) || []) {
           if (s && s.secretKey && s.secretValue) {
             const k = s.secretKey;
             if (seen.has(k)) continue;
             seen.add(k);
             const v = String(s.secretValue).replace(/[\\"\n]/g, (c) => c === "\n" ? "\\n" : "\\" + c);
             process.stdout.write(k + "=" + v + "\n");
           }
         }
       } catch (e) {
         log("CodeCaps: Infisical fetch error: " + (e && e.message ? e.message : "unknown"));
         process.exit(0);
       }
     })();
   ' > "${OUT}" 2> >(grep -v '^::' >&2 || true); then
  :
fi

if [[ ! -s "${OUT}" ]]; then
  echo "CodeCaps: no Infisical secrets exported for ${REPO_NAME} (env=${INFISICAL_ENV:-dev}).  Continuing."
  exit 0
fi

# 4.  Write the dotenv file (mode 0600) and the matching source shim.
install -m 0600 /dev/null "${ENV_FILE}"
cat "${OUT}" > "${ENV_FILE}"
cat > "${SOURCE_FILE}" <<EOF
# Source this file to load ${REPO_NAME} Infisical secrets into the current shell.
# set -a; . "${ENV_FILE}"; set +a
EOF
chmod 0600 "${SOURCE_FILE}"

echo "CodeCaps: loaded $(wc -l < "${ENV_FILE}") Infisical secret(s) into ${ENV_FILE}"
