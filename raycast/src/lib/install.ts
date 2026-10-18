import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

const run = promisify(execFile);

export const STOPLIGHT_BUNDLE_ID = "com.timwheeler.stoplight";
export const STOPLIGHT_RELEASES = "https://github.com/timmywheels/stoplight/releases/latest";
/** Stoplight ships its app as a versioned `Stoplight-<version>.zip` asset, so the URL is resolved per release. */
export const STOPLIGHT_RELEASES_API = "https://api.github.com/repos/timmywheels/stoplight/releases/latest";

/** Finds the `Stoplight-<version>.zip` download URL on the latest release. */
export async function resolveZipURL(apiURL: string = STOPLIGHT_RELEASES_API): Promise<string> {
  const response = await fetch(apiURL, {
    headers: { Accept: "application/vnd.github+json" },
    redirect: "follow",
    signal: AbortSignal.timeout(30_000),
  });
  if (!response.ok) throw new InstallError(`Couldn't reach GitHub releases: ${response.status} ${response.statusText}`);
  const body = (await response.json()) as { assets?: { name?: string; browser_download_url?: string }[] };
  const assets = body.assets ?? [];
  const zip =
    assets.find((a) => /^Stoplight-.*\.zip$/i.test(a.name ?? "")) ??
    assets.find((a) => /\.zip$/i.test(a.name ?? "") && /stoplight/i.test(a.name ?? ""));
  if (!zip?.browser_download_url) throw new InstallError("The latest release has no Stoplight zip to download.");
  return zip.browser_download_url;
}

export type InstallStep = "downloading" | "verifying" | "installing" | "opening";

export class InstallError extends Error {}

/** Installs Stoplight from GitHub's latest release, then opens it. Returns where it landed. */
export async function installStoplight(onStep: (step: InstallStep) => void = () => undefined): Promise<string> {
  const work = await mkdtemp(join(tmpdir(), "stoplight-install-"));
  try {
    onStep("downloading");
    const zip = join(work, "Stoplight.zip");
    await download(await resolveZipURL(), zip);
    const app = await installFromZip(zip, work, applicationsFolders(), onStep);
    onStep("opening");
    await run("/usr/bin/open", [app]);
    return app;
  } finally {
    await rm(work, { recursive: true, force: true });
  }
}

export async function download(url: string, to: string): Promise<void> {
  const response = await fetch(url, { redirect: "follow", signal: AbortSignal.timeout(120_000) });
  if (!response.ok) throw new InstallError(`Download failed: ${response.status} ${response.statusText}`);
  await writeFile(to, Buffer.from(await response.arrayBuffer()));
}

/** /Applications when it's writable, else ~/Applications, which doesn't need an admin. */
export const applicationsFolders = () => ["/Applications", join(homedir(), "Applications")];

/**
 * Unzips the app, refuses anything that isn't Stoplight signed with a Developer ID and notarized,
 * and copies it into the first Applications folder that takes it.
 */
export async function installFromZip(
  zip: string,
  work: string,
  destinations: string[],
  onStep: (step: InstallStep) => void = () => undefined,
): Promise<string> {
  const unpacked = join(work, "unpacked");
  await run("/usr/bin/ditto", ["-x", "-k", zip, unpacked]);
  const app = join(unpacked, "Stoplight.app");
  if (!existsSync(app)) throw new InstallError("The download didn't contain Stoplight.app.");

  onStep("verifying");
  await verifyStoplight(app);

  onStep("installing");
  for (const folder of destinations) {
    const target = join(folder, "Stoplight.app");
    if (existsSync(target)) throw new InstallError(`${target} already exists. Open it instead.`);
    try {
      await run("/bin/mkdir", ["-p", folder]);
      await run("/usr/bin/ditto", [app, target]);
      return target;
    } catch {
      continue;
    }
  }
  throw new InstallError(`Couldn't copy Stoplight into ${destinations.join(" or ")}.`);
}

export async function verifyStoplight(app: string): Promise<void> {
  const { stdout: id } = await run("/usr/bin/defaults", ["read", join(app, "Contents", "Info"), "CFBundleIdentifier"]);
  if (id.trim() !== STOPLIGHT_BUNDLE_ID) throw new InstallError(`Unexpected app in the download: ${id.trim()}`);
  try {
    await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app]);
    await run("/usr/sbin/spctl", ["--assess", "--type", "execute", app]);
  } catch {
    throw new InstallError(
      "The download isn't signed and notarized the way Stoplight's releases are, so it wasn't installed.",
    );
  }
}
