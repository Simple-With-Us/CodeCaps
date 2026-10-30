// Pure build planner.  No network, uploads or release state changes.
// One shared MERGE-TIMESTAMP build per app across iOS and macOS (owner, Oct 29 2026).
// next = max(S, M + 1), a plain integer, where S is the committer date of the
// commit being built (HEAD, i.e. the squash-merge commit on main) in
// America/Chicago as YYYYMMDDHHMM, and M is the highest first numeric
// component among EVERY build (expired included, all version trains, old
// timestamp-style builds included) of the app on iOS and of its paired macOS
// app, plus every extra floor (Sparkle pairedBuildFeed max).  No 1000 floor
// and no 9999 cap.  A rebuild of the same commit still goes up, because M
// then holds the last build.  A result wider than 12 digits throws: the ship
// gate only accepts 12-digit builds, so planning one wider can never ship.
export function nextSharedBuild({iosBuilds, macBuilds, extraFloors = [], complete, mergeStamp}) {
  if (complete !== true || !Array.isArray(iosBuilds) || !Array.isArray(macBuilds)) {
    throw new Error('complete build inventory required');
  }
  if (typeof mergeStamp !== 'string' || !/^[1-9][0-9]{11}$/.test(mergeStamp)) {
    throw new Error('malformed merge stamp');
  }
  if (!Array.isArray(extraFloors)) throw new Error('malformed build inventory');
  for (const floor of extraFloors) {
    // A floor is a Sparkle <sparkle:version> max, which can be wider than a
    // safe integer, so digit strings ride through untouched; numbers keep the
    // old shape.
    if (typeof floor === 'number') {
      if (!Number.isSafeInteger(floor) || floor < 0) throw new Error('malformed build inventory');
    } else if (typeof floor === 'string') {
      if (!/^[0-9]+$/.test(floor)) throw new Error('malformed build inventory');
    } else {
      throw new Error('malformed build inventory');
    }
  }
  // Validate everything before computing; malformed evidence is never ignored.
  const re = /^[0-9]+(\.[0-9]+){0,2}$/;
  for (const value of [...iosBuilds, ...macBuilds]) {
    if (typeof value !== 'string' || !re.test(value)) throw new Error('malformed build inventory');
  }
  const stamp = BigInt(mergeStamp);
  let highest = null;
  for (const value of [...iosBuilds, ...macBuilds]) {
    const first = BigInt(value.split('.')[0]);
    if (highest === null || first > highest) highest = first;
  }
  for (const floor of extraFloors) {
    const candidate = BigInt(floor);
    if (highest === null || candidate > highest) highest = candidate;
  }
  const next = highest === null ? stamp : (highest + 1n > stamp ? highest + 1n : stamp);
  const build = String(next);
  if (build.length > 12) throw new Error('planned build exceeds 12 digits');
  return {build};
}
