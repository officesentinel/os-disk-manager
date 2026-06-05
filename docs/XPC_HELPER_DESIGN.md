# SMAppService XPC Helper — Design Doc (Phase 3.2)

**Status:** scaffolding committed, integration pending Apple Developer ID.
**Owner-decisions required before implementation:** Team ID, Apple ID for notarytool.

---

## 1. Problem statement

Today the GUI invokes `/usr/local/bin/diskwipe-engine` via `sudo -n` thanks
to a blanket `NOPASSWD` sudoers entry at `/etc/sudoers.d/disk-verify`. This
is **not shippable** because:

1. The sudoers grant lets *any* process running as the installing user
   execute the engine as root — not just our GUI.
2. Reinstalling the app requires the user to manually re-run the install
   script as `sudo` to drop the sudoers file.
3. Touch ID prompts depend on the user's `/etc/pam.d/sudo_local` config —
   we can't depend on that being correct.
4. Apple's notarization service won't reject the bundle for this, but a
   security-conscious user will refuse to install.

## 2. Replacement architecture

```
┌──────────────┐                                    ┌─────────────────────┐
│              │   NSXPCConnection (mach service)   │                     │
│  DiskWipe.app│ ──────────────────────────────────▶│ DiskWipeHelper.xpc  │
│   (GUI)      │                                    │  (LaunchDaemon,     │
│              │ ◀──────────────────────────────────│   runs as root)     │
└──────────────┘   Codable JSON over XPC            └─────────────────────┘
       │                                                     │
       │                                                     ▼
       │                                       ┌───────────────────────────┐
       │                                       │ Authorization Services    │
       │                                       │ — per-action right        │
       │                                       │   ("…helper.run",         │
       │                                       │    "…helper.repartition") │
       │                                       │ — Touch ID / pwd prompt   │
       │                                       └───────────────────────────┘
       │                                                     │
       └─────────── only the GUI's code signature ───────────┘
                    is allowed to connect (validated by
                    helper before honouring each request)
```

## 3. Mach service name

`org.officesentinel.disk-manager.helper` — referenced in:
- `Resources/Entitlements/DiskWipeApp.entitlements` →
  `com.apple.security.temporary-exception.mach-lookup.global-name`
- `Resources/Entitlements/DiskWipeHelper.entitlements` →
  `com.apple.security.application-identifier`
- `LaunchDaemons/org.officesentinel.disk-manager.helper.plist` →
  `MachServices` dictionary
- Build script: `Scripts/notarize/sign.sh` substitutes the Team ID into
  the helper's code-requirement string.

## 4. XPC protocol surface

The GUI's existing `EngineClient` (Phase 1.2) becomes a thin wrapper around
`NSXPCConnection`. The wire protocol mirrors the engine CLI 1:1 — this
keeps the migration mechanical.

```swift
@objc protocol DiskWipeHelperXPC {
    // Read-only commands — no auth prompt.
    func list(reply: @escaping ([[String: Any]], Error?) -> Void)
    func smartReport(disk: String, reply: @escaping ([String: Any]?, Error?) -> Void)
    func partitions(disk: String, reply: @escaping ([String: Any]?, Error?) -> Void)
    func history(serial: String?, reply: @escaping ([[String: Any]], Error?) -> Void)
    func snapshot(disk: String, reply: @escaping ([String: Any], Error?) -> Void)

    // Destructive commands — Authorization right required.
    // The helper checks `AuthorizationCopyRights` BEFORE doing the work.
    // The GUI passes the AuthorizationRef as serialized external form.
    func run(disk: String, mode: String, authData: Data,
             reply: @escaping ([String: Any], Error?) -> Void)
    func repartition(disk: String, scheme: String, specs: [String],
                     authData: Data,
                     reply: @escaping ([String: Any], Error?) -> Void)
    func format(volume: String, fs: String, name: String, authData: Data,
                reply: @escaping ([String: Any], Error?) -> Void)
    func resize(volume: String, size: String, add: [String], authData: Data,
                reply: @escaping ([String: Any], Error?) -> Void)
    func delPart(volume: String, authData: Data,
                 reply: @escaping ([String: Any], Error?) -> Void)
    func addVolume(volume: String, shrinkTo: String, fs: String, name: String,
                   authData: Data,
                   reply: @escaping ([String: Any], Error?) -> Void)

    // Long-running streaming command — uses a reply object with a callback.
    func scan(disk: String, mode: String, thresholdMs: Int,
              progress: DiskWipeScanProgress)
}

@objc protocol DiskWipeScanProgress {
    func event(_ json: Data)
    func done(_ summary: Data, error: Error?)
}
```

## 5. Authorization rights

Registered via `AuthorizationRightSet` at first launch. We split rights
into three tiers by privilege level:

**Tier A — destructive (per-action prompt, every time):**

| Right name                                           | Default rule          | Prompt label                                |
|------------------------------------------------------|-----------------------|---------------------------------------------|
| `org.officesentinel.disk-manager.run`                | `authenticate-admin`  | "DiskManager wants to ERASE %@."            |
| `org.officesentinel.disk-manager.repartition`        | `authenticate-admin`  | "DiskManager wants to repartition %@."      |
| `org.officesentinel.disk-manager.format`             | `authenticate-admin`  | "DiskManager wants to format %@."           |
| `org.officesentinel.disk-manager.resize`             | `authenticate-admin`  | "DiskManager wants to resize %@."           |
| `org.officesentinel.disk-manager.delPart`            | `authenticate-admin`  | "DiskManager wants to delete partition %@." |
| `org.officesentinel.disk-manager.addVolume`          | `authenticate-admin`  | "DiskManager wants to add a volume on %@."  |

**Tier B — privileged read (session-scoped, prompt once per launch):**

These commands need root for raw `/dev/diskN` access (so they cannot be
"not protected") but are non-destructive. Using rule `authenticate-admin`
with `timeout` = `<session-end>` so the user authenticates once and
subsequent reads in the same launch reuse the credential. This avoids
the UX-destroying pattern of "auth prompt every 5 seconds while
the dashboard auto-refreshes" while still keeping a privileged barrier.

| Right name                                           | Rule                         | Prompt label                              |
|------------------------------------------------------|------------------------------|-------------------------------------------|
| `org.officesentinel.disk-manager.snapshot`           | `authenticate-admin`, session| "DiskManager wants to read SMART data."   |
| `org.officesentinel.disk-manager.scan`               | `authenticate-admin`, session| "DiskManager wants to surface-scan %@."   |
| `org.officesentinel.disk-manager.smart`              | `authenticate-admin`, session| "DiskManager wants to read SMART data."   |

**Tier C — unprivileged (no root needed, no prompt):**

| Right name                                           | Rule                         |
|------------------------------------------------------|------------------------------|
| `org.officesentinel.disk-manager.list`               | `allow`                      |
| `org.officesentinel.disk-manager.history`            | `allow`                      |
| `org.officesentinel.disk-manager.partlist`           | `allow`                      |

`authenticate-admin` triggers Touch ID if `/etc/pam.d/sudo_local` enables
`pam_tid.so`; otherwise password. Session-scoped rights honour the user's
"Authenticate for X minutes" timeout configured in System Settings.

> **Why scan/snapshot aren't `allow`:** both call `smartctl` and
> `dd if=/dev/diskN`, which need root to bypass `/etc/authorization`
> read restrictions. An unauthenticated XPC client asking the helper to
> scan a connected disk would leak SMART data (serial, family, wear,
> hour count) — those are tracking-grade identifiers.

## 6. Helper code-requirement validation

Before honouring any XPC connection, the helper must validate the calling
process's code signature so a malicious unsigned app can't impersonate the
GUI.

**⚠️ Security note — do NOT use `connection.processIdentifier` for this.**
A pid-based lookup has a TOCTOU race: between the moment the helper reads
the pid and the moment `SecCodeCheckValidity` runs, the calling process
can `exec()` into a different binary, defeating the check. Apple's
sample-code guidance (`SimpleXPC`, WWDC 2020 session 10025) is to use the
client's *audit token* — it is bound to the original process identity at
connection time and survives any subsequent exec.

```swift
import Security

private func validate(connection: NSXPCConnection) -> Bool {
    // 1. Capture the audit token bound to this connection.
    let token = connection.auditToken               // sizeof(audit_token_t) == 32 bytes
    let tokenData = Data(bytes: withUnsafeBytes(of: token) { Data($0) })

    // 2. Resolve a SecCode for the *connection-bound* identity.
    var code: SecCode?
    let attrs: [CFString: Any] = [kSecGuestAttributeAudit: tokenData]
    guard SecCodeCopyGuestWithAttributes(nil, attrs as CFDictionary, [], &code) == errSecSuccess,
          let c = code else { return false }

    // 3. Build the Designated Requirement template.
    //    TEAM_ID is patched in by Scripts/notarize/sign.sh at build time
    //    from $TEAM_ID — see scripts for the sed/awk substitution recipe.
    let req = """
    identifier "org.officesentinel.disk-manager"
    and anchor apple generic
    and certificate leaf[subject.OU] = "\(TEAM_ID)"
    """
    var reqRef: SecRequirement?
    guard SecRequirementCreateWithString(req as CFString, [], &reqRef) == errSecSuccess,
          let r = reqRef else { return false }

    return SecCodeCheckValidity(c, [], r) == errSecSuccess
}
```

`NSXPCConnection.auditToken` is API since macOS 11; we already target
macOS 14 so this is unconditional. The check must run inside
`shouldAcceptNewConnection` BEFORE setting `exportedInterface` and
`exportedObject` on the connection — a misordered helper would expose
the protocol to an unvalidated client.

`TEAM_ID` is patched in by `Scripts/notarize/sign.sh` at build time.

## 7. Migration

On the GUI's first launch after upgrading from a sudoers-based version:

1. Detect `/etc/sudoers.d/disk-verify` exists.
2. Show a one-time alert: "Remove legacy sudoers entry?"
3. On accept → run `osascript -e 'do shell script "rm /etc/sudoers.d/disk-verify" with administrator privileges'`.
4. Register the SMAppService daemon.
5. Subsequent privileged actions use XPC + Authorization.

## 8. LaunchDaemons plist

Saved at `Contents/Library/LaunchDaemons/org.officesentinel.disk-manager.helper.plist`
inside the GUI bundle. `SMAppService.daemon(plistName:)` registers it on
demand. Template lives at `Resources/LaunchDaemons/`.

## 9. Open questions

- **TCC / Full Disk Access**: the helper still needs FDA for raw `/dev/diskN`
  even as root. We must surface a "grant Full Disk Access to DiskWipeHelper"
  dialog on first launch.
- **Engine binary location**: today `/usr/local/bin/diskwipe-engine`. In the
  XPC model the binary lives inside the helper bundle at
  `Contents/MacOS/diskwipe-engine` and is invoked by the helper's main()
  via `Process()` (same as today, but now from a privileged context with
  validated authorisation).
- **Streaming events**: scan() uses an XPC reply object; `Reporter.write`
  and `Snapshot.write` events flow back as JSON `Data` chunks. Need to
  verify XPC reply objects can be retained across multi-second streams.
