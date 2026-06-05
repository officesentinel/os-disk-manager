# Production-Readiness Roadmap

This roadmap converts the current personal-tool build into a publicly distributable
application. Items are grouped into phases; each item has a rationale, the work,
and a rough effort estimate. Phases are ordered by ROI — finishing Phase 1 alone
already changes the security and reliability story significantly.

Legend: ⏱ = effort in working days · 🔥 = blocker for public release · ⭐ = high
user-visible value.

---

## Phase 1 — Stop the bleeding (1 week)

Eliminates the worst bugs and the biggest security wart. Should be done before
sharing with anyone.

### P1.1 Replace `mkdir` lock with `flock` ⏱ 0.5 🔥
**Why:** if engine crashes between `mkdir` and `defer rmdir`, the daily lock
directory remains forever and *all* future snapshots for that disk silently
fail with reason `concurrent-write`.
**Work:** use `flock(LOCK_EX|LOCK_NB)` on an opened file descriptor — the
kernel releases the lock automatically when the process dies.
**Done when:** kill -9 of engine mid-write leaves no stale lock; next call succeeds.

### P1.2 Unify `Process` spawn into one `EngineClient` ⏱ 1 ⭐
**Why:** the same `runObjectSync` / `runArray` / `runData` pattern is duplicated
in `DiskHealth`, `EngineRunner`, `ScanRunner`, `PartitionManager`, `HistoryManager`
(five copies). Future fixes (timeout, retry, sandbox) need to land in five places.
**Work:** new `EngineClient` actor with `call(_:) -> Result<Any, EngineError>`;
all runners depend on it via constructor injection. Type-safe response decoding.
**Done when:** sed shows one `Process()` for engine spawns + zero in runners.

### P1.3 Audit and fix the 76 `try?` swallow points ⏱ 1 🔥
**Why:** report write failures, log write failures, snapshot write failures all
return success silently. User sees "✓ Saved" pointing at a non-existent file.
**Work:** classify each `try?` site into:
  - **Genuinely best-effort** (e.g. `chownToUser` — no recovery anyway) → keep,
    log at WARN level.
  - **User-visible result** (report export, snapshot write) → `do/catch` with
    structured error, surface in UI.
  - **State change** (settings file write) → `do/catch`, retry or back-off.
**Done when:** failed report save shows a localised "✗ couldn't save" toast.

### P1.4 Disk events via DiskArbitration instead of polling ⏱ 1 ⭐
**Why:** every active tab spawns `sudo engine list` every 3 seconds → forever.
Floods `/var/log/system.log`, drains battery on portables, race-prone.
**Work:** `DASessionRegisterCallback` for `kDADiskAppearedCallback` /
`kDADiskDisappearedCallback`. Runners subscribe, refresh **only on events**.
Polling remains as fallback only if DA unavailable.
**Done when:** `top -pid <engine pid count>` stays at 0 on idle.

### P1.5 Log rotation ⏱ 0.5
**Why:** engine + GUI logs are append-forever; a stuck loop can write GB.
**Work:** size-based rotation in `Logger`/`AppLog`: at 5 MB → rename to
`engine-YYYY-MM-DD.1.log`, keep 3 generations. Optional `gzip` of rotated files.
**Done when:** running engine in a tight loop for 1 hour produces ≤ 20 MB total.

**Phase 1 total: ~1 week.**

---

## Phase 2 — Tests + CI (~3 days)

Stop regressions. Apple Silicon is the only build target — no universal binary
work, no Intel Homebrew path juggling.

### P2.1 XCTest skeleton + critical paths ⏱ 2 ⭐  ✅ initial pass
**Why:** 6 360 LoC with zero tests guarantees regressions on every refactor.
**Done:** `Tests/DiskwipeEngineTests/` SPM target wired up via `@testable import
diskwipe_engine` (works on full Xcode; CLT-only environments lack XCTest and
must rely on CI). Initial suite covers the three highest-risk pure functions:
  - `TierClassifier.classify` — DB miss, heuristic fallback, capacity
    numerology, IronWolf vs IronWolf Pro disambiguation, nil-safety
  - `Capabilities.compute` — EFI/Recovery lockdown, NTFS read-only,
    APFS/HFS+ full management, ExFAT/ext can-format-not-resize, delete
    requires resizable previous, first-partition-not-deletable
  - `Snapshot.isSameLocalDay` — same-day, prior-day, next-day, month
    boundary, empty/malformed stamps

**Deferred to a P2.1b round:** fixture-driven `Smart.fullReport` parsing
(needs captured `smartctl --json=c` payloads), `Partitions.layout` parsing
(needs captured `diskutil list -plist` payloads), `DiskDatabase.match`
(needs verified golden cases). All three require curated fixture files —
worth doing after the first PR cycle when patterns are settled.

### P2.2 CI on GitHub Actions ⏱ 1 ⭐  ✅
**Done:** `.github/workflows/ci.yml` with `macos-14` runners (Apple Silicon
M1). Pipeline runs `swift build -c release --arch arm64`, `swift test -c
release --arch arm64`, plus a smoke step that invokes the built engine with
`list` and a `snapshot --disk disk999` (non-existent — must skip gracefully).
Also asserts `bundle.sh` has its arm64 hard-fail guard intact.

**Phase 2 total: ~3 days.**

> Intel Mac is **deliberately not a target** — there are no Phase 2 items to
> add Intel support. The build script and `Tools` helper assume Apple Silicon
> Homebrew at `/opt/homebrew`. If a contributor sends a PR to add Intel
> support, the answer is: out of scope.

---

## Phase 3 — Production security (2 weeks)

Eliminate the NOPASSWD sudoers blanket grant. This is the hardest blocker for
public distribution.

### P3.1 Apple Developer ID enrolment 🔥  ✅ checklist ready
**Why:** required for code signing, notarization, GateKeeper compliance.
Without it ad-hoc only — users see "developer cannot be verified" on every
launch, can't auto-update.
**Work:** $99/year Apple Developer Program; create a Developer ID Application
certificate; install in Keychain.
**Done:** Owner-actionable checklist at [docs/DEVELOPER_ID_SETUP.md](docs/DEVELOPER_ID_SETUP.md)
covering enrollment, certificate generation, App Store Connect API key
setup, secrets file layout, and CI wiring. Cannot complete without Owner
running the steps; build pipeline auto-detects TEAM_ID and switches from
ad-hoc to Developer ID signing.
**Done when (Owner side):** `codesign -dv` shows the Team ID.

### P3.2 SMAppService privileged helper ⏱ 5 🔥  ◐ design doc ready
**Why:** replace blanket `NOPASSWD: /usr/local/bin/diskwipe-engine` with a
properly authorised helper. Each dangerous action (wipe, repartition) prompts
for biometric/password via macOS Authorization Services.
**Done:** Full design specification at [docs/XPC_HELPER_DESIGN.md](docs/XPC_HELPER_DESIGN.md):
mach service name, full XPC protocol surface (DiskWipeHelperXPC), all
Authorization right names + prompt labels, code-requirement validation
recipe, migration plan for the legacy sudoers entry, LaunchDaemons plist
layout, open questions (TCC / FDA for helper). Implementation gated by
P3.1 — requires Team ID at build time. Once Owner finishes P3.1, this
becomes a 3-5 day Swift implementation slot against the spec.
**Done when:** sudoers no longer required; each `run`/`repartition` triggers
biometric prompt; helper passes Apple notarization.

### P3.3 Notarization pipeline ⏱ 1 🔥  ✅ scripts ready
**Why:** macOS won't launch unsigned/non-notarized apps from the internet without
a clear nag.
**Done:** Two scripts at `Scripts/notarize/`:
  - `sign.sh` — hardened-runtime codesign of helper + engine + outer .app,
    with entitlement attachment. Auto-falls-back to ad-hoc when TEAM_ID is
    not set (local dev). Verified working in ad-hoc mode on Apple Silicon.
  - `notarize.sh` — `xcrun notarytool submit --wait`, polls until terminal
    state, surfaces the notary log on failure, staples + validates on
    success. Uses App Store Connect API key (.p8) for auth.
Both gated by P3.1 (need Team ID + API key). CI release.yml integration
deferred until first successful local run by Owner.
**Done when:** clean Mac (downloaded fresh DMG) opens app without warning.

### P3.4 Hardened runtime + entitlements ⏱ 0.5  ✅
**Why:** required for notarization. Plus reduces blast radius if exploited.
**Done:** Two entitlement plists in `Resources/Entitlements/`:
  - `DiskWipeApp.entitlements` — app sandbox OFF (raw disk access requires
    it), hardened-runtime exemptions explicitly DISABLED (no JIT, no
    unsigned executable memory, no library-validation bypass, no debugger,
    no dyld env vars), mach-lookup whitelist for the helper service,
    user-selected file r/w for report export.
  - `DiskWipeHelper.entitlements` — daemon entitlements with explicit
    application-identifier, hardened-runtime locked down. Code-requirement
    string template (Team ID patched in by sign.sh).
**Done when:** `codesign --display --entitlements` shows the locked-down set.

**Phase 3 total: ~2 weeks. Phase 3 → app can be safely shared with users.**

---

## Phase 4 — Distribution + polish (1 week)

### P4.1 DMG packaging + auto-update ⏱ 2 ⭐
**Why:** users expect a DMG drag-to-Applications, not a git clone.
**Work:** `create-dmg` for installer; integrate **Sparkle** framework for in-app
auto-update from a static appcast hosted on GitHub Pages or our own CDN. Sign
the appcast with EdDSA.
**Done when:** double-click DMG → drag to Applications → first launch → app
notices version 0.2 is available and prompts.

### P4.2 Crash reporter ⏱ 1
**Why:** crashes today are silent (no `~/Library/Logs` aggregator). Without
telemetry we won't see production issues.
**Work:** integrate **PLCrashReporter** or **Sentry**. Opt-in by default with
GDPR-friendly toggle.
**Done when:** test crash sends a report to our endpoint with redacted PII.

### P4.3 Localised release notes + in-app changelog ⏱ 0.5
**Why:** users should see "what's new" on update without leaving the app.
**Work:** Sparkle release notes URL, localised per Lang. In-app "About → What's
new" pane.

### P4.4 Help / inline tooltips polish ⏱ 1
**Why:** technical labels (DZAT, PLP, sanitize) need contextual hover help that
links to documentation.
**Work:** all `.help()` strings have a "learn more" URL going to a Hugo-built
docs site. Localised. Same site is the public landing page.

### P4.5 Accessibility audit ⏱ 0.5
**Why:** SwiftUI gives a lot for free but custom chips and HFlow may break
VoiceOver, contrast and Dynamic Type.
**Work:** run Accessibility Inspector; add `.accessibilityLabel`, sensible
hierarchy, ensure all interactive elements ≥ 44 pt hit target.

**Phase 4 total: ~1 week.**

---

## Phase 5 — Cross-platform universality (open-ended)

### P5.1 Linux / Ubuntu engine port ⏱ 5+
**Why:** engine is Swift but uses Foundation + macOS-specific paths/permissions.
Most logic could be lifted to a Linux host that has SwiftLang.
**Work:** replace `diskutil` with `lsblk`/`sgdisk`, `mkfs.*`; `caffeinate` with
`systemd-inhibit`; TCC concept doesn't exist on Linux → root sufficient. Keep
the JSON event protocol identical so other front-ends can attach.
**Use case:** server-side health monitoring of OfficeSentinel storage nodes.

### P5.2 Headless / CLI mode polish ⏱ 1
**Why:** sysadmins want `os-disk-manager --report disk0 --json | jq .` not a GUI.
**Work:** main.swift already has subcommands — add `--no-color`, proper
exit codes, man page.

### P5.3 NVMe / SAS coverage ⏱ 2
**Why:** today's code mostly assumes ATA; NVMe-specific commands (Deallocate,
Sanitize, Format NVM) are stubbed.
**Work:** detect protocol, branch into NVMe paths; add Sanitize-NVMe to the UI.

### P5.4 Web dashboard (optional) ⏱ open-ended
**Why:** fleet view across multiple machines.
**Work:** engine reports snapshots to a central endpoint; thin React/Svelte
dashboard for ops.

---

## Out of scope (deliberately)

- **Intel Mac support** — Apple Silicon (M1-M5) is the only target. No
  universal binary, no Rosetta testing, no `/usr/local`-based Homebrew paths.
- **iPad / iOS** — disk-access permissions don't exist on those platforms.
- **Windows** — completely different APIs; would be a separate codebase.
- **Block-level data recovery** — wrong tool category.
- **Cloud sync of history** — privacy concern; users can sync `~/disk-reports`
  via iCloud Drive themselves.

---

## Effort summary

| Phase | Effort | Cumulative state |
|---|---|---|
| 1 — Stop the bleeding | ~5 days | Safe for personal use of a colleague |
| 2 — Tests + CI | ~3 days | Apple Silicon coverage, regressions caught |
| 3 — Production security | ~10 days | Publicly distributable to Apple Silicon Macs |
| 4 — Distribution + polish | ~5 days | First public alpha |
| 5 — Advanced (Linux engine / NVMe) | open | OfficeSentinel-wide deployment |

**Phases 1–4 ≈ ~23 working days of focused work.**

> Scope reminder: Apple Silicon (M1 / M2 / M3 / M4 / M5) only. Intel Mac and
> Mac App Store sandbox are both intentionally out of scope.

---

## Decision gates

Before starting each phase, decide:

- **Before P3:** is public release actually the goal? If just internal — skip
  Phase 3, ship internally with a strict whitelist of user accounts.
- **Before P4:** Sparkle vs. Mac App Store? App Store requires sandboxing → no
  raw disk access. So **App Store is out**, direct distribution + Sparkle is
  the path.
- **Before P5:** is the headless/Linux scenario actually wanted? Confirm with
  OfficeSentinel team before investing the 5+ days.
