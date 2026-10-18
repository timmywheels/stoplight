import { fetchViaGh, findGh } from "./github";
import { LoadedPRs } from "./model";
import { fetchSnapshot, STOPLIGHT_SNAPSHOT_URL } from "./snapshot";

export class NoSourceError extends Error {
  constructor() {
    super(
      "Stoplight isn't running and the GitHub CLI wasn't found. Open Stoplight, or install gh and run `gh auth login`.",
    );
  }
}

interface LoadOptions {
  ghPath?: string;
  snapshotURL?: string;
  ghCandidates?: string[];
}

/** Stoplight's snapshot when it's running, otherwise the same searches through the GitHub CLI. */
export async function loadPRs(options: LoadOptions = {}): Promise<LoadedPRs> {
  const snapshot = await fetchSnapshot(options.snapshotURL ?? STOPLIGHT_SNAPSHOT_URL);
  if (snapshot) return { snapshot, source: "stoplight" };
  const gh = findGh(options.ghPath?.trim() || undefined, options.ghCandidates);
  if (!gh) throw new NoSourceError();
  return { snapshot: await fetchViaGh(gh), source: "gh" };
}
