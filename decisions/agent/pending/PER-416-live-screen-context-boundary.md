# PER-416: Live screen-context proof boundary

## Status

Pending maintainer review after the live latency test.

## Context

The next Tab milestone needs to prove that changing on-screen work can be observed and summarized quickly enough for a future accountability coach. Speech is not required. Sending every full-resolution frame to a reasoning model would add cost, latency, privacy exposure, and a queue that can fall behind the user's actual context.

## Proposed decision

1. Keep the approved PER-414 notch rendering unchanged. Put all proof output in a separately closable debug sidecar window that is enabled only by an explicit launch option.
2. Treat real-time sensing and model inference as separate rates. ScreenCaptureKit may sample locally at up to one frame per second, but local visual-change detection suppresses duplicate work. Remote inference waits one second for context to settle, sends changed text context no more often than every five seconds, and uses a 30-second heartbeat for unchanged dwell. The coordinator allows one request at a time and replaces queued work with the newest observation. This leaves most of the approximately three-second acceptable round trip for the provider rather than adding a second three-second debounce.
3. Combine three evidence levels: foreground application metadata, permission-gated window/pixel context, and local Vision OCR. Do not request Accessibility, Automation, microphone, or audio permissions.
4. Use a provider-neutral analysis contract. The first optional remote adapter calls OpenRouter chat completions with `openai/gpt-5.6-luna`, reasoning disabled, a bounded JSON-schema response, and an ephemeral URL session. The model reports a factual summary plus `productive`, `unclear`, or `distracting`; it cannot take actions.
5. Keep captured frames in memory only. Exclude Tab's own windows where supported, hide the cursor, and resize to approximately a 1024-pixel long edge. Send bounded metadata and a local OCR excerpt first. Encode a moderate-quality JPEG only when Luna explicitly reports that visual context is required; request low-detail processing, attempt at most one image per context fingerprint, and enforce a 30-second image cooldown.
6. Remote analysis starts only after the user explicitly enables the screen-context proof and enters an OpenRouter key. For this local prototype the key remains in process memory, is never written to disk or logs, and is cleared when the sidecar stops. OpenRouter routing prefers latency, requires parameter support and zero data retention, and denies data-collecting providers. Provider-returned token counts and billed credits are displayed; credit-purchase fees are separate. A distributed product must use a user-owned key or a backend-minted short-lived credential; it must not ship a permanent provider secret.
7. Preserve the macOS 12.0 deployment target. Weak-link and availability-gate ScreenCaptureKit from macOS 12.3. Do not use GPT Realtime, WebSockets, or voice for this proof.

## Consequences

- The sidecar exposes end-to-end freshness and latency without changing the character UI.
- Local observation works before an API key exists, while the same log can compare Luna's remote latency once a key is supplied.
- Screen frames leave the device only during an explicit remote test; this must remain visible in the sidecar state.
- A one-request/latest-frame policy prevents stale narration from accumulating during rapid scrolling or app switching.

## Rollback

Remove the PER-416 sidecar, capture, OCR, and inference sources; remove `NSScreenCaptureUsageDescription` and the network-client entitlement; restore the PER-414 reproduction recipe. The independent Tab identity and frozen eyes milestone remain intact.
