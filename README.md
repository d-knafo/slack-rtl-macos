# slack-rtl

Automatic right-to-left text support for Slack Desktop on macOS.

Slack's desktop client does not detect Hebrew or Arabic text direction in the
message composer or in message bodies. This script patches the client so that
RTL text renders and aligns correctly, using `dir="auto"` so the browser infers
direction from the content itself.

```bash
./slack-rtl.sh status              # inspect, changes nothing
./slack-rtl.sh patch --dry-run     # show exactly what would happen
./slack-rtl.sh patch               # apply
./slack-rtl.sh restore             # roll back from the automatic backup
```

## Read this before running it

Patching Slack means modifying a signed application bundle and re-signing it
ad-hoc. That has real consequences:

| Consequence | Likelihood |
|---|---|
| **You get signed out of your workspaces.** Slack's token lives in the Keychain, and access to a Keychain item is tied to the app's code signature. | high |
| macOS asks again for microphone / camera / screen-recording permission (huddles, screen sharing). | high |
| Apple notarization is lost. | certain |
| A Slack auto-update overwrites the patch — rerun the script. | certain |
| Slack fails to launch. | low, and `restore` brings it back |

The script takes a full backup of `Slack.app` before touching anything, and
`restore` puts it back. If you would rather not modify a signed app at all, see
[Safer alternative](#safer-alternative).

## Why the old one-liner scripts stopped working

Most `fix.sh` scripts floating around date from Slack 3.x and silently do
nothing on a current client. Four things changed:

1. **`app.asar` is no longer the app.** It now holds two files — a loader that
   picks an architecture. The real code lives in `app-arm64.asar` or
   `app-x64.asar` (~11 MB, 942 files).
2. **`src/stat-cache.js` no longer exists.** Appending to it just creates an
   orphan file that nothing loads.
3. **jQuery is gone** from the bundle, and `DOMSubtreeModified` was removed from
   browsers. The old snippet would throw `ReferenceError` — and when it did run,
   it pegged the CPU.
4. **Electron verifies asar integrity.** `Info.plist` carries an
   `ElectronAsarIntegrity` dictionary with a SHA-256 per archive. Repack an
   archive without updating that hash and **Slack refuses to start**.

## What actually breaks, and why

Rather than guess, the fix was derived by inspecting Slack's live DOM. Three
findings, and only the third is subtle:

1. **Detection is not the problem.** Slack already sets `dir="auto"` on message
   blocks, and the computed direction is correct — `rtl` for Hebrew.
2. **Slack's own stylesheet is the problem.** It ships
   `.p-rich_text_block { text-align: left }`, which pins every line to the left
   edge no matter what the direction resolves to. Of 8 sampled Hebrew blocks,
   **7 had `direction: rtl` together with `text-align: left`** — Hebrew
   correctly identified, then jammed against the wrong margin.
3. **A multi-line message has no per-line element.** It is a single
   `.p-rich_text_section` containing bare text nodes separated by `<br>`. So a
   line of English code inside a Hebrew message inherits the RTL base direction
   and renders with its trailing punctuation flipped to the front:

   ```
   ;const { id, categoryId, isActive } = alert      ← what you see
   const { id, categoryId, isActive } = alert;      ← what you wrote
   ```

Because there is no element per line, no amount of setting `dir` on message
blocks can fix (3). CSS has a property built for exactly this:

```css
.p-rich_text_section, .p-rich_text_block {
  unicode-bidi: plaintext;   /* run bidi per <br>-delimited line */
  text-align: start;         /* follow direction instead of forcing left */
}
```

`unicode-bidi: plaintext` runs the bidi algorithm independently for each line,
so a Hebrew line aligns right and an English line of code beside it stays left,
semicolon intact. `text-align: start` is the logical counterpart of `left`.

That is the entire fix — no DOM rewriting, no observer over the message list,
nothing to keep in sync with Slack's markup. The old `fix.sh` did the opposite:
it forced `text-align: left`, which is the bug itself.

## How the script works

1. **Validate the method first.** The SHA-256 of the asar header is computed for
   an archive that is never modified (`app.asar`) and compared to `Info.plist`.
   If they disagree — Slack already modified, or Electron changed its integrity
   scheme — the script stops before writing anything.
2. **Back up** `Slack.app` in full to
   `~/Library/Application Support/slack-rtl/Slack-<version>.app`.
3. **Extract** `app-<arch>.asar` and append the patch to
   `dist/preload.bundle.js`, which runs in the renderer with DOM access. The
   injected block is delimited by markers, so reapplying it replaces the old
   block instead of stacking copies.
4. **Repack**, reproducing the original set of *unpacked* files exactly. This
   matters: 27 files, 8 of them native `.node` modules, live outside the archive
   on disk. A naive repack seals them inside and Slack crashes on launch. The
   script aborts if the unpacked set diverges.
5. **Recompute** the header hash and write it to `Info.plist` with `PlistBuddy`.
6. **Re-sign** ad-hoc, preserving the bundle identifier and the original
   entitlements.

### One subtlety worth knowing

Slack ships signed with the `library-validation` flag (`0x12000`), which
restricts library loading to binaries carrying the same Team ID (`BQR82RBBHL`).
The native `.node` modules stay signed by Slack, so preserving that flag on an
ad-hoc signature would make them unloadable and the app would crash at startup.
The script therefore re-signs with neither `--options runtime` nor
`--preserve-metadata=flags`, leaving `flags=0x2(adhoc)`.

## Requirements

- macOS (Apple Silicon or Intel)
- Node.js — `brew install node`
- The `asar` npm package, installed automatically if missing

## Tested against

| | |
|---|---|
| Slack | 4.51.191 |
| macOS | 26.x (Darwin 25.5.0) |
| Architecture | arm64 (Apple Silicon) |

The Intel path (`app-x64.asar`) is implemented but has not been exercised on
Intel hardware.

## Rolling back

```bash
./slack-rtl.sh restore
```

Restores the backup taken for your current Slack version, or offers the most
recent one available. A clean reinstall from
[slack.com/downloads/mac](https://slack.com/downloads/mac) always works too.

## Safer alternative

If modifying a signed application is not acceptable — on a managed work machine,
for instance — use Slack in the browser with a [Stylus](https://add0n.com/stylus.html)
rule and skip all of the above:

```css
.p-rich_text_section, .p-rich_text_block, .ql-editor, .ql-editor p {
  unicode-bidi: plaintext !important;
  text-align: start !important;
}
```

This is the same rule the script injects, and it is the quickest way to see the
difference before deciding to patch anything.

## Development

The script can be exercised end to end against a copy of Slack, without
touching the installed app and without `sudo`:

```bash
ditto /Applications/Slack.app /tmp/rig/Slack.app
export SLACK_RTL_APP=/tmp/rig/Slack.app
export SLACK_RTL_BACKUP_ROOT=/tmp/rig/backups
./slack-rtl.sh patch --yes
codesign --verify --deep --strict /tmp/rig/Slack.app
```

`sudo` is used only when the target is not writable by the current user.

## License

MIT
