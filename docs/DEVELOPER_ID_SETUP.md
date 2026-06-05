# Developer ID Setup — Owner-actionable checklist (Phase 3.1)

These steps require Owner credentials and an Apple Developer Program
enrollment. Track progress with the checkboxes.

## 1. Enrol in Apple Developer Program

- [ ] Sign in to https://developer.apple.com with Apple ID
- [ ] Enrol as **Organization** if Office Sentinel exists as a legal entity;
      otherwise **Individual** under the founder's name (lower friction).
      $99 / year either way.
- [ ] Wait for approval (Org: ≈1-3 days; Individual: usually same day).

## 2. Create Developer ID Application certificate

- [ ] In Apple Developer portal → **Certificates, Identifiers & Profiles** →
      **Certificates** → **+** → **Developer ID Application**.
- [ ] Generate a CSR from Keychain Access: Menu → Certificate Assistant →
      Request a Certificate From a Certificate Authority.
- [ ] Upload the CSR; download the .cer; double-click to install into login keychain.
- [ ] **Verify:**
      ```bash
      security find-identity -v -p codesigning | grep "Developer ID Application"
      ```
      Should print one line containing the 10-char Team ID in parentheses.

## 3. Capture identifiers for build-time substitution

Once the certificate is installed, capture these values into a local
secrets file (chmod 600):

```bash
mkdir -p ~/.config/officesentinel
cat > ~/.config/officesentinel/developer-id.env <<'EOF'
# Apple Developer ID — used by Scripts/notarize/sign.sh and notarize.sh
export TEAM_ID="ABCD123456"   # the 10-char ID inside the certificate name
export DEVELOPER_ID_APPLICATION="Developer ID Application: Office Sentinel (ABCD123456)"
EOF
chmod 600 ~/.config/officesentinel/developer-id.env
```

## 4. Generate App Store Connect API key (for notarytool)

The previous approach was Apple-ID + app-specific-password. That still
works but expires per Apple's policy. API keys are the recommended path:

- [ ] App Store Connect → **Users and Access** → **Integrations** → **App Store Connect API**.
- [ ] **Generate API Key**. Role = **Developer** (sufficient for notarytool).
- [ ] Download the .p8 file — Apple shows it **once**. Store at
      `~/Library/Keys/AuthKey_<KEY_ID>.p8` and chmod 600.
- [ ] Capture into the secrets file:
      ```bash
      cat >> ~/.config/officesentinel/developer-id.env <<'EOF'
      export AC_API_KEY_ID="ABCD1234EF"
      export AC_API_ISSUER_ID="00000000-0000-0000-0000-000000000000"
      export AC_API_KEY_PATH="$HOME/Library/Keys/AuthKey_ABCD1234EF.p8"
      EOF
      ```

## 5. Sanity-check the full pipeline once

```bash
set -a && source ~/.config/officesentinel/developer-id.env && set +a
cd ~/src/diskwipe
./bundle.sh                              # build the .app
./Scripts/notarize/sign.sh               # hardened-runtime sign
./Scripts/notarize/notarize.sh           # submit + staple
spctl --assess --type execute --verbose=4 /Applications/DiskWipe.app
# Expect: "/Applications/DiskWipe.app: accepted"
```

## 6. Wire CI

After step 5 passes locally:

- [ ] In GitHub repo → Settings → Secrets and variables → Actions, add:
      - `TEAM_ID`
      - `DEVELOPER_ID_APPLICATION`
      - `AC_API_KEY_ID`
      - `AC_API_ISSUER_ID`
      - `AC_API_KEY_P8`  — base64-encoded contents of the .p8 file
- [ ] Update `.github/workflows/release.yml` (separate workflow, NOT ci.yml)
      to run on git tags `v*` and call `sign.sh` + `notarize.sh`.

## 7. Outstanding decisions

- [ ] **Team name on the certificate** — once set it shows up on every
      "Open Anyway" dialog the user clicks. Pick deliberately
      ("Office Sentinel" preferred over a person's name).
- [ ] **Notarized DMG vs notarized .app inside an unsigned DMG**? Apple
      requires the .app to be notarized; the DMG itself can be signed
      separately. We staple to both for resilience.
