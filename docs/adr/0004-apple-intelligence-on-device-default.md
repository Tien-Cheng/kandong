# Apple Intelligence on this Mac is the default Backend

Fresh installs translate with Apple's on-device Foundation Model (macOS 26+; image input needs macOS 27) rather than Codex or LM Studio, so Kandong works with no sign-in, server or download and text stays on the Mac. Existing users keep the Backend they chose. When Apple Intelligence is off, still downloading or unsupported, the Lookup still shows the offline Reading and the user is told why and offered other Backends; we never fall back silently, because that could send private text off the Mac.

Apple's Private Cloud Compute model is deliberately not used: it needs a managed entitlement (`com.apple.developer.private-cloud-compute`) that requires a paid developer account and provisioning profile, and without it the framework terminates the process instead of throwing — even though its availability check reports it as available. Revisit only if Kandong is ever distributed with that entitlement.

## Considered Options

- Codex as default: best quality, but needs the CLI and a ChatGPT sign-in before the first Lookup.
- Fall back automatically to another Backend when Apple Intelligence is unavailable: surprising, and breaks the on-device promise.
- Private Cloud Compute: larger model and context, but unusable for an ad-hoc-signed app (above).
