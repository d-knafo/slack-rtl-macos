# slack-rtl

[![npm](https://img.shields.io/npm/v/slack-rtl)](https://www.npmjs.com/package/slack-rtl)
[![npm downloads](https://img.shields.io/npm/dm/slack-rtl?label=npm%20downloads)](https://www.npmjs.com/package/slack-rtl)
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Fix right-to-left (Hebrew/Arabic) text rendering in Slack Desktop on macOS.

Slack resolves text direction correctly but its stylesheet forces
`text-align: left`, so Hebrew ends up jammed against the wrong margin. And
because a multi-line message is one element holding bare text nodes split by
`<br>`, a line of English code inside a Hebrew message inherits RTL and comes
out with its punctuation flipped to the front:

```
;const { id, categoryId } = alert      ← what you see
const { id, categoryId } = alert;      ← what you wrote
```

The fix is CSS, injected into Slack's renderer:

```css
.p-rich_text_section, .p-rich_text_block {
  unicode-bidi: plaintext;   /* run bidi per line */
  text-align: start;         /* follow direction instead of forcing left */
}
```

## Install

```bash
brew install d-knafo/tap/slack-rtl   # Homebrew
npm install -g slack-rtl             # npm
npx slack-rtl status                 # no install
```

Or clone the repo and run `./slack-rtl.sh` directly. Requires Node.js and
macOS.

## Usage

```bash
slack-rtl status              # inspect, changes nothing
slack-rtl patch --dry-run     # show what would happen
slack-rtl patch               # apply
slack-rtl restore             # roll back
```

## Before you run it

Patching means modifying a signed app bundle and re-signing it ad-hoc:

- **you will likely be signed out of your workspaces** — Slack's token is in the
  Keychain, and access is tied to the code signature
- macOS may ask again for microphone / camera permission
- **on a managed Mac, screen recording is lost for good** — see
  [Managed Macs](#managed-macs-mdm)
- Apple notarization is lost
- a Slack update overwrites the patch — rerun the script

A full backup is taken before anything is touched, and `restore` puts it back.

## Managed Macs (MDM)

On a company Mac, screen recording is usually granted by a configuration
profile rather than by you, and that profile grants it only to Slack signed by
Slack Technologies:

```
certificate leaf[subject.OU] = BQR82RBBHL and identifier "com.tinyspeck.slackmacgap"
```

Ad-hoc re-signing drops the team identifier, so the patched app stops satisfying
that requirement and `tccd` denies it. **Screen sharing in huddles breaks.**

Nothing says why. System Settings still shows the toggle enabled, because the
panel reports what the profile declares, not whether the installed app matches
it — the only clue is the line underneath: *"This setting has been configured by
a profile"*. And unlike the microphone, you cannot grant it back: the toggle
belongs to the profile, and `tccutil reset` leaves MDM entries alone. Only
`restore`, or reinstalling Slack, undoes it.

`status` reports this, and `patch` warns before touching anything:

```bash
slack-rtl status
```

If you need RTL *and* screen sharing, there are two ways:

- `restore`, and join huddles from the browser on the rare occasions you share
  your screen — Chrome's screen-recording permission is granted by you, so it is
  not pinned to anyone's certificate. The [safer
  alternative](#safer-alternative) below gives you RTL there too.
- ask your IT team to add a PPPC payload for a build signed with a Developer ID
  certificate you control. A requirement on your own team identifier survives
  Slack updates; one pinned to a `cdhash` would break on every re-patch.

Keeping the profile's grant while modifying the bundle is not possible: it would
take Slack's own signing certificate.

## If it stops at "App Management is blocking writes"

macOS 14+ forbids one app from modifying another's bundle. It is a TCC control,
so `sudo` does not lift it:

```
cp: /Applications/Slack.app/Contents/Resources/app-arm64.asar: Operation not permitted
```

Enable your terminal under **System Settings → Privacy & Security → App
Management**, then quit and reopen it:

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles"
```

The script checks this before taking a backup or quitting Slack, so hitting it
costs nothing.

## How it works

1. Verifies its hashing method against an archive it never modifies, and stops
   if it disagrees with `Info.plist`
2. Backs up `Slack.app` to `~/Library/Application Support/slack-rtl/`
3. Injects the CSS into `dist/preload.bundle.js` inside `app-<arch>.asar`
4. Repacks, reproducing the 27 *unpacked* files exactly — 8 are native `.node`
   modules that would crash Slack if sealed into the archive
5. Recomputes the `ElectronAsarIntegrity` hash, without which Slack refuses to
   launch
6. Re-signs ad-hoc, dropping `library-validation` so those native modules stay
   loadable

Tested on Slack 4.51.191, macOS 26, arm64. The Intel path is implemented but
untested.

## Safer alternative

To avoid modifying a signed app, use Slack in the browser with the same rule via
[Stylus](https://add0n.com/stylus.html).

## License

MIT
