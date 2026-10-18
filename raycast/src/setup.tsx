import {
  Action,
  ActionPanel,
  Alert,
  Application,
  Clipboard,
  confirmAlert,
  Icon,
  Keyboard,
  List,
  open,
  showHUD,
  showToast,
  Toast,
} from "@raycast/api";
import { InstallError, installStoplight, InstallStep, STOPLIGHT_RELEASES } from "./lib/install";
import { GH_INSTALL_COMMAND, GH_SIGN_IN_COMMAND, SetupStep } from "./lib/setup";
import { waitForStoplight } from "./lib/snapshot";

const STOPLIGHT_REPO = "https://github.com/timmywheels/stoplight";
const GH_SITE = "https://cli.github.com";

const stepTitles: Record<InstallStep, string> = {
  downloading: "Downloading Stoplight…",
  verifying: "Checking its signature…",
  installing: "Installing…",
  opening: "Opening Stoplight…",
};

/** Once Stoplight is open it needs a moment, and a first launch needs its sign-in, before it serves the list. */
async function whenStoplightAnswers(toast: Toast, refresh: () => void) {
  toast.title = "Waiting for Stoplight…";
  if (await waitForStoplight()) {
    toast.style = Toast.Style.Success;
    toast.title = "Stoplight is running";
    toast.message = undefined;
    refresh();
    return;
  }
  toast.style = Toast.Style.Success;
  toast.title = "Stoplight is open";
  toast.message = "Finish its setup, then refresh here with ⌘R.";
}

async function install(refresh: () => void) {
  const confirmed = await confirmAlert({
    title: "Install Stoplight?",
    message:
      "Downloads the latest release from GitHub (about 15 MB), checks it's signed and notarized, puts it in Applications, and opens it.",
    primaryAction: { title: "Install", style: Alert.ActionStyle.Default },
  });
  if (!confirmed) return;
  const toast = await showToast({ style: Toast.Style.Animated, title: stepTitles.downloading });
  try {
    await installStoplight((step) => (toast.title = stepTitles[step]));
    await whenStoplightAnswers(toast, refresh);
  } catch (error) {
    toast.style = Toast.Style.Failure;
    toast.title = "Couldn't install Stoplight";
    toast.message = error instanceof InstallError ? error.message : String(error);
    toast.primaryAction = { title: "Open Download Page", onAction: () => open(STOPLIGHT_RELEASES) };
  }
}

async function start(stoplight: Application, refresh: () => void) {
  const toast = await showToast({ style: Toast.Style.Animated, title: "Starting Stoplight…" });
  await open(stoplight.path);
  await whenStoplightAnswers(toast, refresh);
}

async function copyCommand(command: string) {
  await Clipboard.copy(command);
  await showHUD(`Copied “${command}”. Paste it into a terminal.`);
}

function StepActions(props: {
  step: SetupStep;
  stoplight?: Application;
  hasBrew: boolean;
  refresh: () => void;
  dismiss: () => void;
}) {
  const { step, stoplight, refresh } = props;
  const main = {
    "install-stoplight": [
      <Action key="install" title="Install Stoplight" icon={Icon.Download} onAction={() => install(refresh)} />,
      <Action.OpenInBrowser key="page" title="Open Download Page" url={STOPLIGHT_RELEASES} />,
      <Action.OpenInBrowser key="about" title="Learn About Stoplight" icon={Icon.Info} url={STOPLIGHT_REPO} />,
    ],
    "start-stoplight": stoplight
      ? [
          <Action
            key="start"
            title="Start Stoplight"
            icon={{ fileIcon: stoplight.path }}
            onAction={() => start(stoplight, refresh)}
          />,
        ]
      : [],
    "install-gh": props.hasBrew
      ? [
          <Action
            key="copy"
            title="Copy Install Command"
            icon={Icon.Terminal}
            onAction={() => copyCommand(GH_INSTALL_COMMAND)}
          />,
          <Action.OpenInBrowser key="site" title="Open GitHub CLI Site" url={GH_SITE} />,
        ]
      : [<Action.OpenInBrowser key="site" title="Open GitHub CLI Site" url={GH_SITE} />],
    "sign-in-gh": [
      <Action
        key="copy"
        title="Copy Sign-In Command"
        icon={Icon.Terminal}
        onAction={() => copyCommand(GH_SIGN_IN_COMMAND)}
      />,
      <Action.OpenInBrowser key="docs" title="Open Sign-In Guide" url={`${GH_SITE}/manual/gh_auth_login`} />,
    ],
  }[step.id];

  return (
    <ActionPanel title={step.title}>
      <ActionPanel.Section>{main}</ActionPanel.Section>
      <ActionPanel.Section>
        <Action
          title="Refresh"
          icon={Icon.ArrowClockwise}
          onAction={refresh}
          shortcut={Keyboard.Shortcut.Common.Refresh}
        />
        <Action
          title="Don't Show Again"
          icon={Icon.EyeDisabled}
          onAction={props.dismiss}
          shortcut={Keyboard.Shortcut.Common.Remove}
        />
      </ActionPanel.Section>
    </ActionPanel>
  );
}

/** Pinned above the PRs until each piece is in place or dismissed. */
export function SetupSection(props: {
  steps: SetupStep[];
  stoplight?: Application;
  hasBrew: boolean;
  refresh: () => void;
  dismiss: (id: string) => void;
}) {
  if (!props.steps.length) return null;
  return (
    <List.Section title="SET UP">
      {props.steps.map((step) => (
        <List.Item
          key={step.id}
          id={`setup:${step.id}`}
          icon={step.id.endsWith("stoplight") ? "extension-icon.png" : { source: Icon.Terminal }}
          title={step.title}
          subtitle={step.subtitle}
          actions={
            <StepActions
              step={step}
              stoplight={props.stoplight}
              hasBrew={props.hasBrew}
              refresh={props.refresh}
              dismiss={() => props.dismiss(step.id)}
            />
          }
        />
      ))}
    </List.Section>
  );
}
