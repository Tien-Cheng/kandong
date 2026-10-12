# Releasing

Pushing a `v*` tag runs [`release.yml`](.github/workflows/release.yml): it tests, builds `Kandong.app`, signs it with the "Kandong Self-Signed" certificate, publishes `Kandong-<version>.zip` as a GitHub Release, and updates the cask in [Tien-Cheng/homebrew-tap](https://github.com/Tien-Cheng/homebrew-tap).

```sh
git tag v0.2.0 && git push origin v0.2.0
```

Tags with a `-` (`v0.2.0-beta.1`) are published as prereleases and leave the cask alone.

## Why self-signed

Releases aren't notarized, since that needs a paid Apple Developer account, so users click **Open Anyway** on first launch. Signing every release with the same certificate still matters: macOS ties Accessibility and Screen Recording grants to the signing identity, so an update signed with the same certificate keeps them, while ad-hoc builds would make users re-grant on every update. **Don't lose the certificate.** A new one makes every user re-grant permissions once.

## One-time setup

Secrets on this repo (Settings → Secrets and variables → Actions):

| Secret | What |
|---|---|
| `SIGNING_P12_BASE64` | The "Kandong Self-Signed" identity as a base64 `.p12`. Create it with `scripts/make-signing-identity.sh --export id.p12`, which prints the `gh secret set` commands. |
| `SIGNING_P12_PASSWORD` | That `.p12`'s password (printed by the same script). |
| `TAP_DEPLOY_KEY` | Private half of an SSH key whose public half is a **write** deploy key on `Tien-Cheng/homebrew-tap`. |

The identity also lives in your login keychain, so local `scripts/build-app.sh` builds use the same certificate. To move it to another Mac, export it from Keychain Access (My Certificates → Kandong Self-Signed → Export).
