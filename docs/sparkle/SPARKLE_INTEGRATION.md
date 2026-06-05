# Sparkle Auto-Update — Integration Design (Phase 4.1)

**Status:** integration plan + EdDSA key recipe ready; SPM dependency wiring
gated on first signed release.

---

## 1. Library choice

**Sparkle 2.x** (the actively maintained line). It's the de-facto macOS
auto-update framework — used by 1Password, Tower, Things, dozens of indie
apps. Apache 2.0 licence. Native NSXPCConnection-based update model in
Sparkle 2 (vs Sparkle 1's privileged installer helper) plays well with
our SMAppService model.

## 2. Distribution model

```
GitHub Release tag v1.1.0
    │
    ▼
sign + notarize DMG               ← Scripts/notarize/* (Phase 3)
    │
    ▼
Upload as Release asset
    │
    ▼
Generate appcast.xml entry        ← Scripts/release/update-appcast.sh
  · enclosure URL → release asset
  · EdDSA signature of the .dmg
  · version, length, mime, sparkle:fullReleaseNotesLink
    │
    ▼
Commit appcast.xml to repo's gh-pages branch
    │
    ▼
GitHub Pages serves
  https://officesentinel.github.io/os-disk-manager/appcast.xml
    │
    ▼
Sparkle in v1.0 polls the URL daily → notices v1.1.0 → prompts user
```

EdDSA signing means the user is protected even if our GitHub account is
compromised — an attacker who uploads a malicious .dmg can't forge a
valid signature without the EdDSA private key (which lives only on the
release builder's machine, never in CI).

## 3. EdDSA key generation (one-time, Owner-actionable)

```bash
# Install Sparkle's generate_keys tool (ships with Sparkle release zip).
brew install --cask sparkle    # OR download Sparkle-2.x.tar.xz from sparkle-project.org

# Generate keypair. PRIVATE KEY = keychain item; PUBLIC KEY = printed.
$(brew --prefix sparkle)/bin/generate_keys

# Output:
#   "A new keypair has been generated and saved in your keychain.
#    Public key (saved to ./public_key.pem): xxxxxxxxxxxxxxxxxxxxxxxxxxxx"

# Copy the public key string into Info.plist:
#   <key>SUPublicEDKey</key>
#   <string>xxxxxxxxxxxxxxxxxxxxxxxxxxxx</string>
```

The private key NEVER leaves the build machine's keychain. Releases are
signed locally and the artefacts uploaded to GitHub.

## 4. Package.swift dependency

```swift
// Append to package's dependencies array (Phase 4.1 implementation):
.package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),

// And to the DiskWipeApp target's dependencies:
.product(name: "Sparkle", package: "Sparkle"),
```

## 5. Info.plist additions

```xml
<key>SUFeedURL</key>
<string>https://officesentinel.github.io/os-disk-manager/appcast.xml</string>

<key>SUPublicEDKey</key>
<string>WILL_BE_FILLED_AFTER_KEY_GENERATION</string>

<key>SUEnableInstallerLauncherService</key>
<true/>     <!-- Sparkle 2.x XPC installer (replaces SUEnableSystemProfiling) -->

<key>SUEnableAutomaticChecks</key>
<true/>

<key>SUScheduledCheckInterval</key>
<integer>86400</integer>  <!-- daily -->
```

## 6. Swift entry point

```swift
// in DiskWipeApp.swift @main:
import Sparkle

@main
struct DiskWipeApp: App {
    // Sparkle 2 uses an external updater controller.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        WindowGroup { ContentView() }
            .commands {
                CommandGroup(after: .appInfo) {
                    CheckForUpdatesView(updater: updaterController.updater)
                }
            }
    }
}

// Menu item.
struct CheckForUpdatesView: View {
    @ObservedObject var checkForUpdatesViewModel: CheckForUpdatesViewModel
    let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button(Loc.shared.t("menu.checkUpdates")) { updater.checkForUpdates() }
            .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
    }
}
```

Localisation keys to add to all three languages:
- `menu.checkUpdates`: "Check for Updates…" / "Проверить обновления…" / "Buscar actualizaciones…"

## 7. Appcast generator

A small bash script in `Scripts/release/update-appcast.sh`:

```bash
#!/usr/bin/env bash
# Append/replace an entry in appcast.xml for the given DMG.
# Usage: ./update-appcast.sh DiskWipe-1.1.0-arm64.dmg "v1.1.0 release notes"

set -euo pipefail
DMG="$1"
NOTES="${2:-}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    DiskWipe.app/Contents/Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    DiskWipe.app/Contents/Info.plist)"
LENGTH="$(stat -f%z "$DMG")"
SIGNATURE="$($(brew --prefix sparkle)/bin/sign_update "$DMG")"
PUBDATE="$(date -u +'%a, %d %b %Y %H:%M:%S +0000')"
URL="https://github.com/officesentinel/os-disk-manager/releases/download/v${VERSION}/$(basename "$DMG")"

# Render the <item> snippet.
cat <<EOF
        <item>
            <title>Version $VERSION</title>
            <pubDate>$PUBDATE</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <description><![CDATA[$NOTES]]></description>
            <enclosure
                url="$URL"
                length="$LENGTH"
                type="application/octet-stream"
                $SIGNATURE />
        </item>
EOF
```

The result is appended into `appcast.xml` on the gh-pages branch and
pushed; Sparkle clients see the new entry within
`SUScheduledCheckInterval`.

## 8. Risks & open questions

- **First-launch network call**: Sparkle's daily check is a network call.
  We declared no network entitlements explicitly because the main app is
  unsandboxed. If we ever sandbox, we need `com.apple.security.network.client`.
- **EdDSA private key custody**: today on Owner's macOS keychain. Loss
  means the next release can't sign — but EdDSA does NOT support
  rotation cleanly (Sparkle pins the public key in Info.plist; users
  who never update don't see the new key). Keep an encrypted backup on
  a hardware token before shipping v1.0.
- **GitHub Pages availability**: Sparkle gracefully degrades if the feed
  is unreachable (just won't update). But if the Owner ever moves the
  org, the SUFeedURL hard-coded in v1.0 becomes a dead URL forever for
  users who don't update past that pin. Consider a redirector domain
  the Owner controls.
