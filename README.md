# OS Disk Manager

> Native macOS disk inspector, wiper and partition manager for Apple Silicon

**Office Sentinel Disk Manager** — native (arm64) macOS app for inspecting, wiping
and partitioning external disks. Built around a small Swift CLI engine that talks
to `smartctl`, `diskutil` and `mke2fs`; the SwiftUI front-end streams live JSON
events from the engine for progress, speed and surface-scan maps.

**Status:** functional personal tool. Not yet production-hardened — see [ROADMAP.md](ROADMAP.md).

## What it does

- **Dashboard**: SMART health, life remaining, temperature, power-on hours,
  endurance (TBW), DRAM cache / NAND type / PLP / TRIM(Discard) / Sanitize chips,
  disk-class classifier (consumer / enterprise / unknown), data source badge.
- **Erase + test**: zero-fill with live min/avg/max speed, sector-by-sector verify,
  SMART extended self-test, empty GPT, optional eject, sleep-prevention via
  `caffeinate`.
- **Surface scan**: Read / Verify with configurable threshold, live colour-coded
  block-map (240 buckets), latency-band histogram, slow-block list. Results saved
  as a history snapshot.
- **Partitions**: APFS / HFS+ / ExFAT / FAT32 / ext4 (via `mke2fs`). Resize,
  format, repartition, delete; per-operation capability matrix that disables
  actions macOS can't perform (e.g. NTFS resize) with a localised reason.
- **History**: per-disk timeline of snapshots, trend charts (wear / temp / POH /
  defects), side-by-side compare of two snapshots, JSON+MD+HTML export.
- **i18n**: English, Russian, Spanish; auto-detects system language on first
  launch and remembers user override.
- **Disk model database**: ~350 curated SSD/HDD entries shipped with the app,
  pluggable user override at `~/disk-reports/.config/models.json`, optional
  remote refresh.

## Architecture

```
DiskWipe.app (SwiftUI)  ── spawn `sudo -n diskwipe-engine <cmd>` ──►  diskwipe-engine (root)
   ▲ reads newline-delimited JSON events from engine stdout (live progress/speed)
   │
   • DiskHealth      — dashboard data + auto-snapshot
   • EngineRunner    — wipe pipeline orchestration
   • ScanRunner      — surface-scan streaming
   • PartitionManager— diskutil ops
   • HistoryManager  — per-disk snapshot timeline
   • DatabaseUpdater — remote refresh of model DB
```

Engine modules (`Sources/diskwipe-engine/`):

| File | What |
|---|---|
| `main.swift` | CLI dispatch (`list`, `smart`, `partlist`, `run`, `scan`, `snapshot`, `export`, …) |
| `Smart.swift` | smartctl → structured SMART report (incl. TRIM/Discard/Sanitize) |
| `Scan.swift` | block-by-block timed read, latency bands, bucket map |
| `Operations.swift` | zero-fill + verify with SpeedMeter (min/avg/max) |
| `Partitions.swift` | diskutil wrapper + capability matrix |
| `Snapshot.swift` | per-day throttled history snapshots |
| `Reporter.swift` / `ReportExport.swift` | MD / HTML / JSON report generation |
| `DiskDatabase.swift` | bundled + user-override + remote DB lookup |
| `DiskTier.swift` / `CacheInfo.swift` | consumer/enterprise + DRAM/NAND classifier |
| `Logger.swift` / `Shell.swift` / `Paths.swift` | infra |

## Requirements

| | |
|---|---|
| **Architecture** | Apple Silicon (M1 / M2 / M3 / M4 / M5) **only**. Intel Mac is intentionally not supported. |
| **macOS** | 14 (Sonoma) or later |
| **Dependencies** | Homebrew + `smartmontools` + `e2fsprogs` |
| **Permissions** | Full Disk Access for the app bundle; `sudoers` entry for the engine binary |

## Install (current dev workflow)

```bash
brew install smartmontools e2fsprogs
git clone https://github.com/officesentinel/os-disk-manager.git
cd os-disk-manager
./bundle.sh   # builds release, signs ad-hoc, installs to /Applications + /usr/local/bin
```

`bundle.sh` will ask for admin once (Touch ID supported when configured). Then
grant **Full Disk Access** to `/Applications/DiskWipe.app` in System Settings →
Privacy & Security on first launch.

## Limitations (today)

- **NOPASSWD sudoers** — privileged helper via XPC is on the roadmap; today the
  install writes `/etc/sudoers.d/disk-verify`, which is a powerful blanket
  grant. Do not use this build on a shared machine.
- **No code signing** — ad-hoc only; Gatekeeper will prompt on first launch.
- **No tests** — entire 6 360-LoC codebase has zero `XCTest` files. Regressions
  are caught by hand.
- **Apple Silicon only** — arm64-only by design; Intel is not a target. M1 / M2 / M3 / M4 / M5 covered.
- **macOS-only** — no Linux/Windows port (engine logic could be ported, GUI is
  SwiftUI).

## Roadmap

See [ROADMAP.md](ROADMAP.md) for the production-readiness plan: privileged
helper, code signing + notarization, test coverage, universal binary, sudo-free
disk events, log rotation, packaging.

## Languages

The UI is fully localised. Add a language by extending `Localization.swift`
with a new column and adding the `Lang` case. Contributions welcome via PR.

## License

Personal use. No license declared yet — to be decided before public release
(see ROADMAP item P6).
