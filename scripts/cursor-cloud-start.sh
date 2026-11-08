#!/usr/bin/env bash
# Cursor cloud agent start for CodeCaps.
#
# Runs on every agent boot.  When the dashboard has injected the scoped
# CodeCaps prod-root read service token, it reads the configured project and
# exports the secret map for this repo to a 0600 file at
# $HOME/.cursor-cloud-env/codecaps.env, plus a tiny
# codecaps.source.sh that future shells can `source` without printing.
#
# If the dashboard secrets are missing, prints the missing NAMES (never
# values) and exits 0 so the agent boots cleanly.  Never prints a secret
# value at any point.
#
# This boot path keeps its own universal-auth login.  CI uses scoped
# service tokens in scripts/infisical-fetch.mjs, and this script does not
# import it.  The dotenv output here is the form a Linux non-Apple script
# actually needs.
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

# 1b.  Prod-only guard (owner, 2026-10-10).  The dev and staging Infisical
#      environments are retired, so refuse to export from any other
#      environment, whether the value came from .cursor/infisical.env or from
#      the session.  Exit 0 so the agent boot still succeeds.
if [[ "${INFISICAL_ENV:-prod}" != "prod" ]]; then
  echo "CodeCaps: INFISICAL_ENV is '${INFISICAL_ENV}'; only 'prod' is allowed (dev and staging are retired).  Skipping Infisical export."
  exit 0
fi

# 2.  Require the dashboard-injected project and service token by NAME only.
MISSING=()
[[ -z "${INFISICAL_PROJECT_ID:-}" ]] && MISSING+=("INFISICAL_PROJECT_ID")
[[ -z "${INFISICAL_CODECAPS_PROD_ROOT_READ_SERVICE_TOKEN:-}" ]] \
  && MISSING+=("INFISICAL_CODECAPS_PROD_ROOT_READ_SERVICE_TOKEN")
if (( ${#MISSING[@]} > 0 )); then
  echo "CodeCaps: skipping Infisical export.  Add the following names to the Cursor dashboard secrets: ${MISSING[*]}"
  exit 0
fi

# 3.  Fetch the prod-env secrets with this script's own universal-auth
#     login and raw-secrets read, then emit a dotenv file on stdout.  The
#     script does not echo values and does not log the response body.
#     Stderr only carries status.  It does not call scripts/infisical-fetch.mjs.
mkdir -p "${ENV_DIR}"
chmod 0700 "${ENV_DIR}"

OUT="$(mktemp)"
trap 'rm -f "${OUT}"' EXIT

if INFISICAL_SITE_URL="${INFISICAL_DOMAIN:-https://app.infisical.com}" \
   INFISICAL_PROJECT_ID="${INFISICAL_PROJECT_ID:-}" \
   INFISICAL_ENVIRONMENT="${INFISICAL_ENV:-prod}" \
   INFISICAL_SECRET_PATH="${INFISICAL_SECRET_PATH:-/}" \
   INFISICAL_SERVICE_TOKEN="${INFISICAL_CODECAPS_PROD_ROOT_READ_SERVICE_TOKEN}" \
   node -e '
     const site = String(process.env.INFISICAL_SITE_URL || "").replace(/\/+$/, "");
     const projectId = process.env.INFISICAL_PROJECT_ID || "";
     const env = process.env.INFISICAL_ENVIRONMENT || "prod";
     const path = process.env.INFISICAL_SECRET_PATH || "/";
     const token = process.env.INFISICAL_SERVICE_TOKEN || "";
     const log = (m) => process.stderr.write(m + "\n");
     if (!site || !projectId || !token.startsWith("st.")) { log("CodeCaps: Infisical service-token config invalid; skipping."); process.exit(0); }
     (async () => {
       try {
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
  echo "CodeCaps: no Infisical secrets exported for ${REPO_NAME} (env=${INFISICAL_ENV:-prod}).  Continuing."
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
