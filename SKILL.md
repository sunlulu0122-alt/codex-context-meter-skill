---
name: codex-context-meter
description: Install, configure, diagnose, update, or uninstall the Codex Context Meter companion app on macOS or Windows. Use when a user shares this Skill or its GitHub repository and asks Codex to install the context meter, set up login startup, troubleshoot visibility or permissions, upgrade it, remove it, or verify its real context/token/quota/task-ETA and automatic handoff behavior.
---

# Codex Context Meter

Operate only through the bundled deterministic scripts. Preserve user data and report every failed check exactly.

## Safety

- Never read `~/.codex/auth.json`.
- Never write any Codex SQLite database.
- Never disable Gatekeeper, antivirus, execution policy, or another system-wide security control.
- Describe the macOS app as locally ad-hoc signed, not Apple-notarized.
- Describe the Windows 1.4 native app as locally compiled from bundled source and not Authenticode-signed. The older Electron installer is an explicit compatibility fallback only and remains protected by its pinned SHA-256 check.
- Let the user grant Accessibility permission personally. Open the correct Settings page when requested, but never claim permission was granted without verification.
- Treat displayed percentages, quotas, task ETA, and task state as valid only when the app obtained their documented real signals. Do not invent substitutes.
- Disclose that the 80% automatic handoff feature is not read-only: after the current task finishes, it writes a local handoff package and uses the official Codex App Server to create and open the next task. It does not interrupt, archive, or delete the source task.

## Choose the operation

Detect the host OS first:

- On macOS, run the matching `scripts/*-macos.sh`.
- On Windows, run the matching `scripts/*-windows.ps1` from PowerShell.
- On another OS, stop and explain that the current version supports only macOS and Windows.

Use `install` for a first installation or repair, `diagnose` for inspection, `update` for a fast-forward Skill update plus reinstall, and `uninstall` only after the user explicitly requests removal.

## Install

Before installation, ensure this Skill came from:

`https://github.com/sunlulu0122-alt/codex-context-meter-skill`

Prefer a Git clone. The scripts reject an unexpected Git remote. For a user-supplied verified local copy, pass the explicit local-source option and disclose that provenance cannot be verified from Git.

macOS:

```bash
bash scripts/install-macos.sh
bash scripts/diagnose-macos.sh
```

The installer verifies bundled source hashes, builds with the local Swift compiler, creates the app under `~/Applications`, applies ad-hoc signing, installs a per-user LaunchAgent, starts the app, and verifies the process. If Swift is unavailable, it downloads the pinned architecture-matching fallback from the GitHub release and verifies its hardcoded SHA-256 before locally re-signing it.

After installation, ask the user to open **System Settings → Privacy & Security → Accessibility** and enable **Codex 上下文仪表**. Offer to open that page:

```bash
open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'
```

Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\diagnose-windows.ps1
```

The default Windows path compiles the bundled C# source with the Windows .NET Framework compiler, producing a small WinForms executable without Electron, Chromium, Node.js, or a large runtime download. It installs only for the current user under `%LOCALAPPDATA%\Codex Context Meter`, creates a current-user login-startup entry, starts the app, and verifies the executable and process. `Bypass` applies only to that PowerShell process; never change machine or user execution policy. Disclose that the locally compiled executable is not Authenticode-signed.

If the Windows .NET Framework compiler is unavailable, stop with the exact error. Use the older Electron installer only when the user explicitly accepts the approximately 95 MB compatibility fallback and provides a verified installer path:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1 -UseElectronFallback -InstallerPath <verified-path>
```

## Diagnose

Run the OS-specific diagnose script and preserve its output. Distinguish:

- app files present;
- signature/hash or executable checks;
- startup configuration present;
- process running;
- Accessibility trusted on macOS;
- Codex local data paths readable without opening credentials;
- UI visibility, which requires Codex to be open on a supported conversation view.

If macOS Accessibility is false, guide the user to grant it and run diagnosis again. If Windows cannot be tested from the current host, say so rather than claiming success.

## Update

Run the matching update script:

```bash
bash scripts/update-macos.sh
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\update-windows.ps1
```

The update script permits only a clean Git worktree and a fast-forward pull from the approved repository, then invokes the installer. Never reset, clean, force-pull, or discard local changes.

## Uninstall

Confirm that the user asked to uninstall, then run:

```bash
bash scripts/uninstall-macos.sh
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\uninstall-windows.ps1
```

The scripts remove only the companion app and its startup entry. They preserve Codex conversations and databases. Report the exact removed paths and any leftovers.

## Final report

State:

1. detected OS and architecture;
2. source repository and revision when verified;
3. operation performed;
4. installation/startup/process verification results;
5. permissions the user must still grant;
6. any checks not performed on this host.
