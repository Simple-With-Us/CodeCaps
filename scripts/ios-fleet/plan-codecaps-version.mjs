import { planCodeCapsVersion } from "./version-plan.mjs";

const [commitCount, marketingFloor, buildFloor, forcedVersion, forcedBuild] = process.argv.slice(2);
if ([commitCount, marketingFloor, buildFloor, forcedVersion, forcedBuild].some((value) => value === undefined)) {
  console.error("Usage: plan-codecaps-version.mjs <commit-count> <marketing-floor> <build-floor> <forced-version> <forced-build>");
  process.exit(2);
}

try {
  const plan = planCodeCapsVersion({ commitCount, marketingFloor, buildFloor, forcedVersion, forcedBuild });
  process.stdout.write(`${plan.marketing}\t${plan.build}\n`);
} catch (error) {
  console.error(`CodeCaps version plan refused: ${error.message}`);
  process.exitCode = 2;
}
