# Releasing

Pushing a `v*` tag runs [`release.yml`](.github/workflows/release.yml): it tests, builds `Kandong.app`, signs it with the "Kandong Self-Signed" certificate, publishes `Kandong-<version>.zip` as a GitHub Release with an `appcast.xml` for self-update (see [ADR 0007](docs/adr/0007-self-update-with-sparkle.md)), and updates the cask in [Tien-Cheng/homebrew-tap](https://github.com/Tien-Cheng/homebrew-tap). Installed copies (0.4.0 and later) find the new release within a day through `releases/latest/download/appcast.xml`.

```sh
git tag v0.2.0 && git push origin v0.2.0
```

Tags with a `-` (`v0.2.0-beta.1`) are published as prereleases with no appcast, and leave the cask alone, so installed copies don't update to them.

## Why self-signed

Releases aren't notarized, since that needs a paid Apple Developer account, so users click **Open Anyway** on first launch. Signing every release with the same certificate still matters: macOS ties Accessibility and Screen Recording grants to the signing identity, so an update signed with the same certificate keeps them, while ad-hoc builds would make users re-grant on every update. **Don't lose the certificate.** A new one makes every user re-grant permissions once.

## One-time setup

Secrets on this repo (Settings → Secrets and variables → Actions):

| Secret | What |
|---|---|
| `SIGNING_P12_BASE64` | The "Kandong Self-Signed" identity as a base64 `.p12`. Create it with `scripts/make-signing-identity.sh --export id.p12`, which prints the `gh secret set` commands. |
| `SIGNING_P12_PASSWORD` | That `.p12`'s password (printed by the same script). |
| `TAP_DEPLOY_KEY` | Private half of an SSH key whose public half is a **write** deploy key on `Tien-Cheng/homebrew-tap`. |
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle's EdDSA private key, which signs each update. Export it with Sparkle's `generate_keys --account kandong -x key.txt`, then `gh secret set SPARKLE_ED_PRIVATE_KEY < key.txt` and delete the file. |

## The update key

Installed copies only accept an update signed by the EdDSA key whose public half is `SUPublicEDKey` in `scripts/build-app.sh`. The private half is in your login Keychain (account `kandong`, created by Sparkle's `generate_keys`). **Don't lose it either:** without it, installed copies can't update, and users would have to download a new version by hand. Back it up with `generate_keys --account kandong -x` and store the file somewhere safe. Sparkle's tools come in its release tarball (`Sparkle-2.10.0.tar.xz`, `bin/`).

To try an update locally, build with `KANDONG_FEED_URL=http://127.0.0.1:8765/appcast.xml` and a `KANDONG_BUILD` number, then serve a higher-numbered build's zip and `scripts/make-appcast.sh` output with `python3 -m http.server 8765`.

The identity also lives in your login keychain, so local `scripts/build-app.sh` builds use the same certificate. To move it to another Mac, export it from Keychain Access (My Certificates → Kandong Self-Signed → Export).
