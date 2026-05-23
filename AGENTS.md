# Fence

## Purpose
Fence is a macOS application for scheduling and enforcing website and app blocking with no mid-block escape hatch. This repository also contains the privileged helper, CLI/helper tools, and the licensing/web backend pieces required to build and operate the product.

## Scope
In scope: the macOS app, privileged daemon, CLI/helper targets, blocking engine, shared Objective-C code, licensing/trial logic, release/build tooling, and the small server/web components that support license generation and activation.
Out of scope: hosted infrastructure configuration outside this repo (Railway, Cloudflare, Stripe dashboards), support operations, and artifacts generated outside version control unless they are explicitly checked in.

## Key constructs
- **Fence** — the current product name and user-facing branding for this fork; many source files, targets, and bundle identifiers still use the historical `SelfControl` naming.
- **commit** — the app action that locks in a weekly blocking schedule; not a git commit.
- **selfcontrold** — the privileged LaunchDaemon installed via `SMJobBless` that enforces blocks and persists state across reboots.
- **Block Management** — the subsystem that applies website and app blocking through `/etc/hosts`, PF rules, and blocked-process termination.
- **SelfControl Killer / SCKillerHelper** — helper targets used for app termination and recovery/testing flows around blocking.

## Active threads
- Linear project: `Fence` in team `PER` (`https://linear.app/usefence/project/fence-4dbdbd3a1e95`).
- Current setup/readiness ticket: `PER-219` (`https://linear.app/usefence/issue/PER-219/prepare-macos-fence-checkout-for-feature-work`).
- For new non-trivial feature work, attach to an existing `PER` ticket under the Fence project or create one before implementation.

## How we work here
- Start by checking `git status`.
- This checkout at `/users/dross/fence` is the canonical work location for macOS Fence changes.
- DVC is intentionally not used for this repo. Do not require `dvc status` or DVC artifact tracking unless the user explicitly decides to introduce DVC later.
- If local build setup is unclear or broken, the user has approved SSHing into their MacBook to inspect `~/selfcontrol`, which is known to build and compile. Treat that checkout as a reference for setup comparison, not as the source of truth for commits here unless explicitly instructed.
- Fresh clones require `git submodule update --init --recursive` to populate `ArgumentParser/`.
- The pinned `ArgumentParser` commit may no longer be fetchable from GitHub. If submodule init fails with `not our ref 61a9bbbd234bae51ea798f9752ffe582042aefda`, fetch it from the MacBook reference checkout: `git -C ArgumentParser fetch macbook:/Users/vishaljain/selfcontrol/ArgumentParser 61a9bbbd234bae51ea798f9752ffe582042aefda && git -C ArgumentParser checkout --detach 61a9bbbd234bae51ea798f9752ffe582042aefda`.
- `Sparkle.framework/` is ignored but required at the repo root for app compilation. If missing, copy it from the MacBook reference checkout or install the matching framework before building.
- Install CocoaPods prerequisites, then run `pod install` and work from `SelfControl.xcworkspace`, not `SelfControl.xcodeproj`.
- On the Mac mini, unsigned compile/test checks use `CODE_SIGNING_ALLOWED=NO` because the machine can compile without the `org.eyebeam.Fence` provisioning profile.
- Main app compile check: `xcodebuild -workspace SelfControl.xcworkspace -scheme SelfControl -configuration Debug CODE_SIGNING_ALLOWED=NO build`
- Tests: `xcodebuild -workspace SelfControl.xcworkspace -scheme SelfControl -configuration Debug CODE_SIGNING_ALLOWED=NO -destination 'platform=macOS' test`
- License server dev loop: `cd server && npm install && npm start`
- Local macOS builds may require code-signing updates and `Secrets.xcconfig`; see `SETUP.md` and `BUILD_MACOS26.md`.
- GUI smoke tests can be automated locally with `peekaboo` once the app is built and launchable.

## Decisions of record
- No human decision records are checked in yet. Use `decisions/human/` for durable decisions and treat `SYSTEM_ARCHITECTURE.md`, `SETUP.md`, and `BUILD_MACOS26.md` as current technical context until that record exists.
