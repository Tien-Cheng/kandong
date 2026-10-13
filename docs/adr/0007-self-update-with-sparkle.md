# Kandong updates itself with Sparkle, from GitHub Releases

Updating used to mean Homebrew or replacing the app by hand, and because releases aren't notarized, a downloaded app meant **Open Anyway** again. Kandong now updates itself with [Sparkle](https://sparkle-project.org) 2: it reads `appcast.xml` from the latest GitHub Release once a day, downloads a newer build in the background and installs it when Kandong quits. Kandong lives in the menu bar and rarely quits, so the menu offers **Restart to Update** once an update is ready (Sparkle's `willInstallUpdateOnQuit` handler), and scheduled checks never open a window (gentle reminders). Sparkle downloads without quarantine, so updates don't trigger Gatekeeper.

Each update is checked twice: Sparkle verifies the zip's EdDSA signature against `SUPublicEDKey`, and the new app is signed with the same "Kandong Self-Signed" certificate, so Accessibility and Screen Recording grants carry over. The release workflow signs the zip with the private key from a repo secret and publishes the appcast next to it; prereleases get none, so `releases/latest` never offers one. The Homebrew cask is marked `auto_updates true` so `brew upgrade` leaves self-updating installs alone.

A self-signed certificate has no Team ID, so the hardened runtime's library validation refused the bundled `Sparkle.framework` ("different Team IDs"). The app is signed with `com.apple.security.cs.disable-library-validation` (`scripts/Kandong.entitlements`); Sparkle's own helpers are signed inside out with the same certificate. Its XPC services, needed only by sandboxed apps, are left out.

## Considered Options

- Our own updater (GitHub API check plus download and replace): the check is easy, but swapping a running app, relaunching and verifying what was downloaded is what Sparkle already does well.
- Homebrew only: many users install from the zip, and brew updates only when asked.
- Keep library validation by notarizing with a Team ID: needs the paid developer account Kandong doesn't use (see RELEASING.md).
