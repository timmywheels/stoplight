import { execFile } from "node:child_process";
import { promisify } from "node:util";

const run = promisify(execFile);

/** Stoplight feeds the list; the GitHub CLI fills in the rest and stands in when Stoplight isn't running. */
export type StoplightSetup = "running" | "installed" | "missing";
export type GhSetup = "ready" | "signedOut" | "missing";

export type SetupStepID = "install-stoplight" | "start-stoplight" | "install-gh" | "sign-in-gh";

export interface SetupStep {
  id: SetupStepID;
  title: string;
  subtitle: string;
}

/** What's missing, most useful first. Dismissed steps stay hidden unless nothing else can load the list. */
export function setupSteps(stoplight: StoplightSetup, gh: GhSetup, dismissed: string[] = []): SetupStep[] {
  const steps: SetupStep[] = [];
  const listFromGh = stoplight !== "running" && gh === "ready";
  if (stoplight === "missing") {
    steps.push({
      id: "install-stoplight",
      title: "Install Stoplight",
      subtitle: "Menu bar lights, notifications, and a window to review each PR",
    });
  }
  if (stoplight === "installed") {
    steps.push({
      id: "start-stoplight",
      title: "Start Stoplight",
      subtitle: listFromGh
        ? "It's installed but not running, so this list comes from the GitHub CLI"
        : "It's installed but not running",
    });
  }
  const ghReason =
    stoplight === "running"
      ? "Adds unresolved threads, requested reviewers, queue drops and live CI"
      : "Lists your PRs without Stoplight, and adds live CI and the conversation";
  if (gh === "missing") steps.push({ id: "install-gh", title: "Install the GitHub CLI", subtitle: ghReason });
  if (gh === "signedOut") steps.push({ id: "sign-in-gh", title: "Sign in to the GitHub CLI", subtitle: ghReason });

  const nothingLoads = stoplight !== "running" && gh !== "ready";
  return nothingLoads ? steps : steps.filter((step) => !dismissed.includes(step.id));
}

/** Reads whether a token is stored, without printing it or calling GitHub. */
export async function ghSetup(gh: string | undefined): Promise<GhSetup> {
  if (!gh) return "missing";
  try {
    await run(gh, ["auth", "token", "--hostname", "github.com"], { timeout: 5000 });
    return "ready";
  } catch {
    return "signedOut";
  }
}

export const GH_INSTALL_COMMAND = "brew install gh && gh auth login";
export const GH_SIGN_IN_COMMAND = "gh auth login";
