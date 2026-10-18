import { CheckResult, PullRequest, Snapshot } from "../src/lib/model";

export const check = (name: string, state: CheckResult["state"], url?: string): CheckResult => ({ name, state, url });

export function makePR(overrides: Partial<PullRequest> = {}): PullRequest {
  return {
    id: "PR_1",
    repo: "acme/app",
    number: 1,
    title: "Add a thing",
    url: "https://github.com/acme/app/pull/1",
    isDraft: false,
    updatedAt: "2026-09-25T12:00:00Z",
    headSha: "0123456789abcdef0123456789abcdef01234567",
    checks: [check("build", "success")],
    author: "me",
    status: "open",
    summary: "",
    headRefName: "feature",
    baseRefName: "main",
    mergeState: "clean",
    review: "none",
    ...overrides,
  };
}

export function makeSnapshot(overrides: Partial<Snapshot> = {}): Snapshot {
  return { writtenAt: "2026-09-25T12:00:00Z", prs: [], pinnedIDs: [], sections: [], ...overrides };
}
