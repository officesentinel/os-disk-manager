# Crash Reporting — Design (Phase 4.2)

**Status:** strategy committed; implementation lands in P4.2 alongside
Sparkle hookup so the user sees one consent dialog covering both.

---

## 1. The shipping decision: PLCrashReporter, not Sentry

| Aspect              | PLCrashReporter (local-only)          | Sentry / Bugsnag / Crashlytics |
|---------------------|---------------------------------------|---------------------------------|
| GDPR exposure       | Minimal — file stays on user's disk   | Cross-border transfer, DPA req |
| Symbolication       | Needs our dSYM upload to a static site| Vendor SaaS handles it          |
| Cost                | $0                                    | $26-100/month minimum tier      |
| Data sovereignty    | User-owned                            | Vendor-owned                    |
| Operational burden  | None (no API keys, no quotas)         | Maintenance + key rotation      |
| Production analysis | Manual fetch from user                | Web dashboard, alerts           |

For a disk-wiping app where the user base is small and security-conscious,
PLCrashReporter's local-file-only model is the right default. Users opt in
to *report* a crash; they aren't automatically transmitted. Trade-off:
slower production-issue discovery, but trust-aligned with the product.

## 2. Architecture

```
crash occurs
    │
    ▼
PLCrashReporter handler  ← installed in DiskWipeApp.init()
    │
    ▼
crash report written to
   ~/Library/Application Support/OSDiskManager/crashes/<UUID>.plcrash
    │
    ▼
NEXT app launch detects unsent reports
    │
    ▼
Shows opt-in modal:
   "We found a crash from 2026-06-04 14:32. Would you like to send the
    technical details to help fix it? You can preview what gets sent."
    │
    ├── Preview ──→ pretty-printed text in TextEditor; shows stack trace,
    │               OS version, app version, redacted disk identifiers
    │               (serials hashed with SHA-256 prefix-8)
    │
    ├── Send ────→ POST plain text to
    │               https://crashes.officesentinel.org/diskmanager/v1
    │               (signed with the user's installation UUID for dedup,
    │                NOT the system UUID and NOT keyed to the user)
    │               then delete the local file
    │
    └── Discard ─→ delete the local file
```

## 3. PII redaction policy

Before display in the preview pane:
- **Disk serials** → `SHA256(serial)[..8]` ("a3f0d12c…")
- **Volume mount paths** → `/Volumes/<name>` → `/Volumes/<redacted>`
- **`smartctl --json` body** → omitted entirely; only the operation that
  triggered the crash is included
- **Username / home path** → `~/foo` → `~/foo`, but `/Users/<name>/foo`
  → `~/foo`
- **File paths the user opened via dialog** (report export) → filename
  only, no parent path

Code lives in `Sources/DiskWipeApp/CrashReporting/Redactor.swift` —
testable against fixture strings.

## 4. SPM dependency

```swift
.package(url: "https://github.com/microsoft/PLCrashReporter.git", from: "1.11.1")
```

Wired into the DiskWipeApp target. Init at the very top of @main:

```swift
import CrashReporter

@main
struct DiskWipeApp: App {
    init() {
        let config = PLCrashReporterConfig(
            signalHandlerType: .mach,        // catch traps, not just signals
            symbolicationStrategy: .all
        )
        let reporter = PLCrashReporter(configuration: config)
        reporter?.enable()

        // Detect unsent reports on every launch.
        if let data = reporter?.loadPendingCrashReportData() {
            UnsentReportQueue.shared.add(data)
            reporter?.purgePendingCrashReport()
        }
    }
    ...
}
```

## 5. Sender endpoint

Provisional URL: `https://crashes.officesentinel.org/diskmanager/v1`
(needs Server-team setup). Until that exists, the "Send" button is
hidden and only "Preview / Discard" are shown — local-only collection.

Accepts plaintext body, returns 204. Server stores the payload in
`/var/log/diskmanager-crashes/YYYY-MM-DD/<sha256-of-body>.txt` for
manual review. No DB. No retention policy beyond 30 days.

## 6. Open questions

- **Should the sender endpoint be on a sub-CA / pinned cert?** Leaning
  yes — the same EdDSA key that signs Sparkle releases can co-sign a
  cert pin so users who never update at least don't talk to an MITM.
- **Crashes during wipe**: PLCrashReporter doesn't help mid-operation
  crashes that leave disks half-erased. That class needs a journal in
  the engine — out of scope for Phase 4, slot for Phase 5.
- **Crash counter as auto-update signal**: Sparkle's `sparkle:critical`
  flag forces an update for known-buggy versions. If we ship v1.2.0
  with a wipe-corruption bug, can we recall it via the appcast? Yes —
  v1.2.1's <item> includes `<sparkle:criticalUpdate sparkle:version="1.2.0"/>`.
