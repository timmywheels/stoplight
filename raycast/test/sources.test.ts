import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { createServer, Server } from "node:http";
import { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  checkRunState,
  checksOf,
  fetchViaGh,
  mapNode,
  PRNode,
  snapshotFromResponse,
  statusContextState,
  utcDay,
} from "../src/lib/github";
import { loadPRs, NoSourceError } from "../src/lib/source";
import { fetchSnapshot, parseSnapshot } from "../src/lib/snapshot";
import { makePR, makeSnapshot } from "./fixtures";

const servers: Server[] = [];
afterEach(() => servers.splice(0).forEach((s) => s.close()));

async function serve(handler: Parameters<typeof createServer>[1]): Promise<string> {
  const server = createServer(handler);
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return `http://127.0.0.1:${(server.address() as AddressInfo).port}/prs.json`;
}

async function closedPortURL(): Promise<string> {
  const url = await serve(() => undefined);
  servers.pop()?.close();
  return url;
}

const tmp = mkdtempSync(join(tmpdir(), "stoplight-raycast-"));

function fakeGh(name: string, stdout: string, exitCode = 0): string {
  const path = join(tmp, name);
  writeFileSync(path, `#!/bin/sh\ncat <<'JSON'\n${stdout}\nJSON\nexit ${exitCode}\n`);
  chmodSync(path, 0o755);
  return path;
}

const node = (overrides: Partial<PRNode> = {}): PRNode => ({
  id: "PR_1",
  number: 1,
  title: "Add a thing",
  url: "https://github.com/acme/app/pull/1",
  isDraft: false,
  state: "OPEN",
  updatedAt: "2026-09-25T12:00:00Z",
  headRefOid: "abc",
  bodyText: "  line one \n\n line two ",
  headRefName: "feature",
  baseRefName: "main",
  author: { login: "me" },
  mergeStateStatus: "DIRTY",
  reviewDecision: "APPROVED",
  repository: { nameWithOwner: "acme/app" },
  commits: {
    nodes: [
      {
        commit: {
          statusCheckRollup: {
            contexts: {
              nodes: [{ __typename: "CheckRun", name: "build", status: "COMPLETED", conclusion: "SUCCESS" }],
            },
          },
        },
      },
    ],
  },
  ...overrides,
});

describe("the app's loopback snapshot", () => {
  it("reads the snapshot Stoplight serves", async () => {
    const snapshot = makeSnapshot({ prs: [makePR()], sections: [{ id: "Mine", title: "My PRs", prIDs: ["PR_1"] }] });
    const url = await serve((_, res) => res.end(JSON.stringify({ ...snapshot, colorProfile: "default" })));
    expect(await fetchSnapshot(url)).toEqual({ ...snapshot, colorProfile: "default" });
  });

  it("carries Stoplight's color-blind profile", async () => {
    const url = await serve((_, res) => res.end(JSON.stringify({ ...makeSnapshot(), colorProfile: "deuteranopia" })));
    expect((await fetchSnapshot(url))?.colorProfile).toBe("deuteranopia");
  });

  it("treats Stoplight's empty pre-sign-in body as no snapshot", async () => {
    const url = await serve((_, res) => res.end("{}"));
    expect(await fetchSnapshot(url)).toBeNull();
  });

  it("returns null when Stoplight isn't running", async () => {
    expect(await fetchSnapshot(await closedPortURL())).toBeNull();
  });

  it("gives up quickly on a hung server", async () => {
    const url = await serve(() => undefined);
    const started = Date.now();
    expect(await fetchSnapshot(url, 200)).toBeNull();
    expect(Date.now() - started).toBeLessThan(1500);
  });

  it("fills fields an older snapshot didn't write", () => {
    const parsed = parseSnapshot({ writtenAt: "2026-09-25T12:00:00Z", prs: [{ id: "x", repo: "a/b", number: 1 }] });
    expect(parsed?.prs[0]).toMatchObject({ checks: [], review: "none", mergeState: "unknown", status: "open" });
    expect(parsed?.sections).toEqual([]);
  });
});

describe("Stoplight's snapshot", () => {
  it("keeps Stoplight's per-PR activity", () => {
    const activity = [
      { id: "c1", kind: "comment", author: "alice", isBot: false, body: "hi", at: "2026-09-29T00:00:00Z", url: "u" },
    ];
    const parsed = parseSnapshot({ writtenAt: "2026-09-29T00:00:00Z", prs: [{ ...makePR(), activity }] });
    expect(parsed?.prs[0].activity).toEqual(activity);
  });
});

describe("GitHub mapping", () => {
  it("maps check run and status context states like Stoplight", () => {
    expect(checkRunState("IN_PROGRESS", null)).toBe("pending");
    expect(checkRunState("COMPLETED", "SUCCESS")).toBe("success");
    expect(checkRunState("COMPLETED", "SKIPPED")).toBe("skipped");
    expect(checkRunState("COMPLETED", "TIMED_OUT")).toBe("failure");
    expect(statusContextState("ERROR")).toBe("failure");
    expect(statusContextState("EXPECTED")).toBe("pending");
  });

  it("keeps only the newest run of a re-run check, per workflow", () => {
    const checks = checksOf({
      statusCheckRollup: {
        contexts: {
          nodes: [
            {
              __typename: "CheckRun",
              name: "test",
              status: "COMPLETED",
              conclusion: "FAILURE",
              completedAt: "2026-09-25T10:00:00Z",
              checkSuite: { workflowRun: { workflow: { name: "CI" } } },
            },
            {
              __typename: "CheckRun",
              name: "test",
              status: "COMPLETED",
              conclusion: "SUCCESS",
              completedAt: "2026-09-25T11:00:00Z",
              checkSuite: { workflowRun: { workflow: { name: "CI" } } },
            },
            {
              __typename: "CheckRun",
              name: "test",
              status: "IN_PROGRESS",
              startedAt: "2026-09-25T09:00:00Z",
              checkSuite: { workflowRun: { workflow: { name: "Nightly" } } },
            },
            { __typename: "StatusContext", context: "vercel", state: "SUCCESS", targetUrl: "https://vercel.com" },
          ],
        },
      },
    });
    expect(checks).toEqual([
      { name: "test", state: "success", url: undefined },
      { name: "test", state: "pending", url: undefined },
      { name: "vercel", state: "success", url: "https://vercel.com" },
    ]);
  });

  it("maps an open PR's merge state, review, and summary", () => {
    expect(mapNode(node())).toMatchObject({
      repo: "acme/app",
      mergeState: "conflicting",
      review: "approved",
      summary: "line one\nline two",
      checks: [{ name: "build", state: "success" }],
    });
  });

  it("reads a merged PR's checks from its merge commit", () => {
    const merged = mapNode(
      node({
        state: "MERGED",
        mergeCommit: {
          statusCheckRollup: {
            contexts: {
              nodes: [{ __typename: "CheckRun", name: "deploy", status: "COMPLETED", conclusion: "FAILURE" }],
            },
          },
        },
      }),
    );
    expect(merged?.status).toBe("merged");
    expect(merged?.checks).toEqual([{ name: "deploy", state: "failure", url: undefined }]);
  });

  it("skips nodes that aren't pull requests", () => expect(mapNode({})).toBeUndefined());

  it("builds My PRs worst-first plus a Merged section", () => {
    const failing = node({
      id: "red",
      commits: {
        nodes: [
          {
            commit: {
              statusCheckRollup: {
                contexts: {
                  nodes: [{ __typename: "CheckRun", name: "t", status: "COMPLETED", conclusion: "FAILURE" }],
                },
              },
            },
          },
        ],
      },
    });
    const snapshot = snapshotFromResponse({
      data: { mine: { nodes: [node({ id: "green" }), failing, {}] }, merged: { nodes: [] } },
    });
    expect(snapshot.sections).toEqual([{ id: "Mine", title: "My PRs", prIDs: ["red", "green"] }]);
  });

  it("surfaces GitHub's error when there is no data", () =>
    expect(() => snapshotFromResponse({ errors: [{ message: "Bad credentials" }] })).toThrow("Bad credentials"));

  it("formats the merged-since day in UTC", () =>
    expect(utcDay(1, new Date("2026-09-25T01:00:00Z"))).toBe("2026-09-24"));
});

describe("fallback through the GitHub CLI", () => {
  const response = JSON.stringify({ data: { mine: { nodes: [node()] }, merged: { nodes: [] } } });

  it("parses gh's output", async () => {
    const snapshot = await fetchViaGh(fakeGh("gh-ok", response));
    expect(snapshot.prs.map((pr) => pr.id)).toEqual(["PR_1"]);
  });

  it("keeps partial data when gh exits non-zero", async () => {
    const snapshot = await fetchViaGh(fakeGh("gh-partial", response, 1));
    expect(snapshot.prs).toHaveLength(1);
  });

  it("throws when gh fails without data", async () => {
    await expect(fetchViaGh(fakeGh("gh-fail", "error: not logged in", 1))).rejects.toThrow();
  });

  it("prefers Stoplight over gh", async () => {
    const url = await serve((_, res) => res.end(JSON.stringify(makeSnapshot({ prs: [makePR({ id: "live" })] }))));
    const loaded = await loadPRs({ snapshotURL: url, ghPath: fakeGh("gh-unused", response) });
    expect(loaded.source).toBe("stoplight");
    expect(loaded.snapshot.prs[0].id).toBe("live");
  });

  it("falls back to gh when Stoplight isn't running", async () => {
    const loaded = await loadPRs({
      snapshotURL: await closedPortURL(),
      ghPath: fakeGh("gh-fallback", response),
    });
    expect(loaded.source).toBe("gh");
  });

  it("explains itself when neither source exists", async () => {
    await expect(
      loadPRs({
        snapshotURL: await closedPortURL(),
        ghPath: join(tmp, "missing"),
        ghCandidates: [],
      }),
    ).rejects.toBeInstanceOf(NoSourceError);
  });
});
