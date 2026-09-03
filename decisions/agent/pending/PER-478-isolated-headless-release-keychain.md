# PER-478: Isolated headless release keychain

## Proposed decision

Run macOS release signing on the canonical Mac mini from a dedicated Keychain
that contains only the selected Fence Developer ID Application identity. Keep
that Keychain on the user's Keychain search list because `codesign` requires it,
but do not make it the default Keychain. Keep it locked at rest, pass it
explicitly to every `codesign` invocation, and pin releases to the identity's
SHA-1 fingerprint.

Store the dedicated Keychain and its generated unlock-password file inside the
mode-`700` `/Users/dross/.private/fence-release` directory, with both files mode
`600`. `scripts/build-release.sh` may unlock this Keychain from the configured
password file for a headless release, but must lock it again on exit. Continue to
use App Store Connect API-key authentication for notarization and
`create-dmg --skip-jenkins` when no Finder session is available. Supply the
existing mode-`600` Sparkle Ed25519 private-key file explicitly so the final ZIP
signature is generated in the same release run without consulting a login
Keychain.

Keep verified Mac-mini-local recovery copies of the otherwise unavailable
pinned `ArgumentParser` commit and ignored Sparkle.framework beside the private
release configuration, with checksums and restore commands in an output-local
`reproduction.txt`. These are recovery inputs, not release artifacts and not a
reason to contact the MacBook during a routine release.

Do not copy the MacBook login Keychain. Migrate only the exact Developer ID
identity whose certificate is authorized by the selected Direct Distribution
profile. Retain the prior Mac mini and MacBook identities as fallbacks until a
Mac-mini-built release has passed signing, notarization, Gatekeeper, and launch
checks. Permanently remove the encrypted PKCS#12 and its one-time transfer
passphrase from both machines immediately after the imported identity and a
throwaway signature have been verified.

## Why this is pending

The user requested MacBook-independent deployment. A dedicated Keychain gives
the headless release process only the signing material it needs, while copying
the login Keychain would also transfer unrelated passwords, certificates, and
private keys. Keeping the Keychain explicit avoids ambiguous identity selection;
locking it outside release runs limits private-key availability and makes the
release dependency auditable.

## Alternatives

- Continue signing on the MacBook whenever SecurityAgent interaction is needed.
- Repair and reuse the Mac mini's renamed login Keychain and its different
  Developer ID identity.
- Create a new Developer ID certificate on the Mac mini instead of migrating an
  existing authorized identity.
