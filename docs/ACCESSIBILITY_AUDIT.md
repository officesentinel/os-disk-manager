# Accessibility Audit — OS Disk Manager (Phase 4.5)

**Audit date:** 2026-06-05
**Auditor:** initial pass by code review (Accessibility Inspector run pending
on Owner's machine — it requires GUI interaction)
**Coverage:** 5 view files, ~6 300 LoC of SwiftUI

---

## Methodology

For each interactive element in every view file:
1. Determine whether VoiceOver would announce something useful by default.
2. Check that the touch target is ≥ 44 × 44 pt (macOS standard click target).
3. Verify icon-only buttons have explicit `.accessibilityLabel`.
4. Decorative images (icons inside labelled buttons) should be marked
   `.accessibilityHidden(true)` so VoiceOver doesn't double-announce.
5. Long lists / grids should use `.accessibilityElement(children: .combine)`
   to avoid spoken element overload.

## Fixed in P4.5 first pass

✅ **DashboardView.diskSelector** — the most critical surface (first thing
the user sees and the most-used controls):
- Gauge icon: `.accessibilityHidden(true)` — decorative
- Picker: `.accessibilityLabel("Select a disk")` (was empty label)
- Loading ProgressView: spoken as "Loading"
- Exporting ProgressView: spoken as "Exporting report"
- Save button: `.accessibilityHint` describes the action
- Refresh button (icon-only): `.accessibilityLabel("Refresh")` +
  `.accessibilityHint` describing what refresh actually does

New localisation keys: `status.loading`, `status.exporting`,
`common.refresh`, `dash.refresh.hint`, `dash.save.hint` — all three
languages (EN/RU/ES).

## Outstanding work — slot P4.5b

The rest of the codebase has the same icon-only-button gap. Items below
listed in priority order (most-used surfaces first):

### DashboardView (12 remaining issues)
- [ ] Identity card SSD/HDD icon — decorative, mark hidden
- [ ] Health gauge — needs a combined accessibility label with the
      numeric value ("Health 87%, normal range")
- [ ] Wear donut — same: "Wear 12% used"
- [ ] Temperature gauge — "Temperature 43 degrees Celsius"
- [ ] Partition map cells — each cell needs label with name + FS + size
- [ ] SMART attribute rows — `.accessibilityElement(children: .combine)`
      on each row so VoiceOver speaks "Power-On Hours 1247, normal"
      in one announcement instead of three
- [ ] All `lock.open` / `lock.shield.fill` icons — decorative
- [ ] Speedometer chips on perf row — combine with value

### PartitionView (~15 issues)
- [ ] All "Format / Resize / Delete / Add" buttons should have hints
      explaining the destructive nature
- [ ] Volume rows should announce caps state
      ("APFS, 100 GB, can format, can resize")
- [ ] Confirmation dialogs should set `.accessibilityFocus` on the
      destructive button so the user has to deliberately move focus

### ScanView (~8 issues)
- [ ] Live block-map grid needs a combined summary label
      ("Surface scan in progress, 47% done, 0 errors so far")
      — speaking 240 cells individually is unusable
- [ ] Threshold slider needs labelled value
- [ ] Band legend chips need labels

### HistoryView (~6 issues)
- [ ] Snapshot list items need combined labels
      ("Wipe, June 4, healthy, 1247 power-on hours")
- [ ] Compare-mode toggles need announcement

### ContentView (~3 issues)
- [ ] Tab labels OK by default (SwiftUI TabView is well-behaved)
- [ ] Language picker should have explicit `.accessibilityLabel`

## Dynamic Type / contrast

Not yet audited. SwiftUI handles Dynamic Type via `.font(.body)` etc.
automatically — but we use `.font(.system(size: 9))` in several chips
(DashboardView L135, L195) which will NOT scale. Replace with
`.font(.caption2)` to honour user's preferred sizing.

Contrast: foreground colours use `.tint`, `.secondary`, `.orange`, `.red`
— these are dynamic colours, OK. Custom green/red mappings in health
chips need a `.high-contrast` variant; not yet provided.

## Tooling steps for the Owner

```bash
# 1. Open the app, then launch Accessibility Inspector.
open -a "Accessibility Inspector"

# 2. In Inspector → Audit tab → choose DiskWipe.app as target → "Run Audit".
#    Each warning has a "Show element" button that highlights the offending
#    control in the running app.

# 3. VoiceOver test (Cmd+F5 to toggle):
#    - Tab through every control
#    - Verify each one is announced with meaningful text + role
#    - The dashboard's auto-refresh should NOT re-announce on every refresh
#      (use .accessibilityElement modifications to stabilise)
```

## Acceptance criteria for P4.5b ("done")

- Zero "Show me" warnings from Accessibility Inspector audit on the four
  primary views (Dashboard, Partition, Scan, History).
- VoiceOver-only walkthrough: a user with eyes closed can identify their
  disk, see its health verdict, and trigger a report export.
- All Dynamic Type sizes from xSmall to AX-XXXL render without truncation
  on the standard window size (1100 × 720).
