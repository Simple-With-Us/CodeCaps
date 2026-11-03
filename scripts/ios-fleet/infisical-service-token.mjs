const SERVICE_TOKEN_PATTERN = /^st\.[^.\s]+\.[^.\s]+$/;

/** Only an explicit full service token may reach the automation secret reader. */
export function hasInfisicalServiceToken(env = process.env) {
  return typeof env.INFISICAL_TOKEN === "string" && SERVICE_TOKEN_PATTERN.test(env.INFISICAL_TOKEN);
}

/** Minimal environment for `fleet-secrets`; machine identity settings never cross. */
export function fleetSecretsEnvironment(env = process.env) {
  if (!hasInfisicalServiceToken(env)) return {};
  const child = {};
  for (const name of [
    "PATH",
    "HOME",
    "TMPDIR",
    "LANG",
    "LC_ALL",
    "INFISICAL_TOKEN",
    "INFISICAL_FLEET_OPS_PROJECT_ID",
    "INFISICAL_PROJECT_ID",
    "INFISICAL_ENVIRONMENT",
    "INFISICAL_SITE_URL",
    "INFISICAL_API_URL"
  ]) {
    const value = env[name];
    if (typeof value === "string" && value.length > 0) child[name] = value;
  }
  return child;
}
