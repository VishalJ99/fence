# PER-444: Trial GitHub Release assets for Fence 3.4.12

## Decision

Fence 3.4.12 will trial storing the signed, notarized ZIP and DMG as assets on
the public `VishalJ99/fence` GitHub Release rather than committing those new
binary files to `fence-web`.

The two Sparkle appcasts and the website remain deployed through Cloudflare
Pages from `fence-web`. Their new 3.4.12 URLs will point to the exact GitHub
Release assets. Existing `/updates/` artifacts and URLs remain unchanged.

## Publication order

1. Build, sign, notarize, staple, checksum, and launch-smoke both artifacts.
2. Create a draft `v3.4.12` GitHub Release at the exact source commit and upload
   the final ZIP and DMG.
3. Publish and independently download both assets to verify their byte lengths
   and SHA-256 values.
4. Only then publish the text-only appcast and website-link changes.

This ordering prevents Sparkle or the website from pointing at an unavailable
or unverified artifact.

## Success criteria

- Sparkle downloads the GitHub-hosted ZIP whose length and EdDSA signature
  match the appcast.
- The website downloads the same verified DMG published on the release.
- No 3.4.12 ZIP or DMG enters the `fence-web` Git tree.
- The live appcasts, release assets, and website link all remain reachable
  without GitHub authentication.

## Rollback

Before the appcast deployment, delete the draft release and tag if validation
fails. After publication, restore the 3.4.11 appcast item and website link before
removing or superseding the faulty 3.4.12 release. Historical `/updates/` files
remain the known-good fallback throughout the trial.
