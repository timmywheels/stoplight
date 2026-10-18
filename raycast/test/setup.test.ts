import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { AddressInfo } from "node:net";
import { readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import { download, installFromZip, InstallError } from "../src/lib/install";
import { ghSetup, setupSteps } from "../src/lib/setup";

const ids = (...args: Parameters<typeof setupSteps>) => setupSteps(...args).map((s) => s.id);

describe("setupSteps", () => {
  it("asks for nothing when Stoplight runs and gh is signed in", () => expect(ids("running", "ready")).toEqual([]));

  it("suggests installing Stoplight first, then whatever gh needs", () => {
    expect(ids("missing", "ready")).toEqual(["install-stoplight"]);
    expect(ids("missing", "missing")).toEqual(["install-stoplight", "install-gh"]);
    expect(ids("installed", "signedOut")).toEqual(["start-stoplight", "sign-in-gh"]);
    expect(ids("running", "missing")).toEqual(["install-gh"]);
  });

  it("says where the list comes from when Stoplight is installed but not running", () => {
    expect(setupSteps("installed", "ready")[0].subtitle).toContain("comes from the GitHub CLI");
    expect(setupSteps("installed", "missing")[0].subtitle).toBe("It's installed but not running");
  });

  it("keeps dismissed steps hidden, unless nothing could load the list without them", () => {
    expect(ids("missing", "ready", ["install-stoplight"])).toEqual([]);
    expect(ids("running", "missing", ["install-gh"])).toEqual([]);
    expect(ids("missing", "missing", ["install-stoplight", "install-gh"])).toEqual(["install-stoplight", "install-gh"]);
  });
});

const work = mkdtempSync(join(tmpdir(), "stoplight-setup-test-"));
afterAll(() => rmSync(work, { recursive: true, force: true }));

function fakeGh(name: string, exitCode: number): string {
  const path = join(work, name);
  writeFileSync(path, `#!/bin/sh\nexit ${exitCode}\n`, { mode: 0o755 });
  return path;
}

describe("ghSetup", () => {
  it("tells missing, signed out and ready apart", async () => {
    expect(await ghSetup(undefined)).toBe("missing");
    expect(await ghSetup(fakeGh("gh-out", 1))).toBe("signedOut");
    expect(await ghSetup(fakeGh("gh-in", 0))).toBe("ready");
  });
});

function fakeApp(dir: string, bundleID: string): string {
  const app = join(dir, "Stoplight.app");
  mkdirSync(join(app, "Contents", "MacOS"), { recursive: true });
  writeFileSync(
    join(app, "Contents", "Info.plist"),
    `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${bundleID}</string><key>CFBundleExecutable</key><string>Stoplight</string></dict></plist>`,
  );
  writeFileSync(join(app, "Contents", "MacOS", "Stoplight"), "#!/bin/sh\n", { mode: 0o755 });
  return app;
}

const zipApp = (app: string, zip: string) => execFileSync("/usr/bin/ditto", ["-c", "-k", "--keepParent", app, zip]);

describe("installFromZip", () => {
  it("refuses an app that claims to be Stoplight but isn't signed and notarized", async () => {
    const dir = mkdtempSync(join(work, "unsigned-"));
    zipApp(fakeApp(dir, "com.timwheeler.stoplight"), join(dir, "Stoplight.zip"));
    const dest = join(dir, "Applications");
    await expect(installFromZip(join(dir, "Stoplight.zip"), dir, [dest])).rejects.toThrow(/signed and notarized/);
    expect(existsSync(join(dest, "Stoplight.app"))).toBe(false);
  });

  it("refuses a different app", async () => {
    const dir = mkdtempSync(join(work, "other-"));
    zipApp(fakeApp(dir, "com.example.other"), join(dir, "Stoplight.zip"));
    await expect(installFromZip(join(dir, "Stoplight.zip"), dir, [join(dir, "Applications")])).rejects.toThrow(
      InstallError,
    );
  });

  it.runIf(existsSync("/Applications/Stoplight.app"))(
    "installs the real, notarized Stoplight into the first folder that takes it, and never over an existing one",
    async () => {
      const dir = mkdtempSync(join(work, "real-"));
      zipApp("/Applications/Stoplight.app", join(dir, "Stoplight.zip"));
      const readOnly = join(dir, "ReadOnly");
      mkdirSync(readOnly);
      execFileSync("/bin/chmod", ["555", readOnly]);
      const dest = join(dir, "Applications");
      const steps: string[] = [];
      const installed = await installFromZip(join(dir, "Stoplight.zip"), dir, [readOnly, dest], (s) => steps.push(s));
      expect(installed).toBe(join(dest, "Stoplight.app"));
      expect(steps).toEqual(["verifying", "installing"]);
      execFileSync("/usr/sbin/spctl", ["--assess", "--type", "execute", installed]);
      await expect(installFromZip(join(dir, "Stoplight.zip"), dir, [dest])).rejects.toThrow(/already exists/);
      execFileSync("/bin/chmod", ["755", readOnly]);
    },
    60_000,
  );
});

describe("download", () => {
  it("saves the file and reports a failed response", async () => {
    const server = createServer((req, res) => {
      if (req.url === "/Stoplight.zip") res.end("zip-bytes");
      else {
        res.statusCode = 404;
        res.end();
      }
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const { port } = server.address() as AddressInfo;
    try {
      const to = join(work, "downloaded.zip");
      await download(`http://127.0.0.1:${port}/Stoplight.zip`, to);
      expect(readFileSync(to, "utf8")).toBe("zip-bytes");
      await expect(download(`http://127.0.0.1:${port}/missing`, to)).rejects.toThrow(/404/);
    } finally {
      server.close();
    }
  });
});
