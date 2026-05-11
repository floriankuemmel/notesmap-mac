# Releasing NotesMap

How to ship a new version. The pipeline is:

```
edit code → bump version → release.sh → upload DMG to GitHub → update appcast.xml → push
```

End-to-end: ~10 minutes once everything is set up.

---

## One-time setup

### 0. Lock down the GitHub repo

The Sparkle update feed lives at `https://raw.githubusercontent.com/<repo>/main/appcast.xml`. Even though every DMG is EdDSA-signed (so an attacker with write access to `main` cannot ship code), an unprotected `main` would let them DoS the update channel or phish via crafted `<description>` release-notes HTML.

Before the first release, on **Settings → Branches** of the GitHub repo, add a branch protection rule for `main`:

- ☑ Require a pull request before merging
- ☑ Require approvals: 1 (or skip on a solo project, but keep the PR requirement)
- ☑ Require status checks to pass (once CI exists)
- ☑ Require linear history (no force-pushes that rewrite history)
- ☑ Do not allow bypassing the above settings (yes, even for admins)
- ☐ Allow force pushes — leave **off**
- ☐ Allow deletions — leave **off**

Also: enable **2FA** on the GitHub account (Settings → Password and authentication → Two-factor authentication).

### 1. Apple Developer Program (~$99/year)

Required to publish notarized builds users can run without a right-click "Open" dance.

- Enroll at <https://developer.apple.com/programs/enroll/>
- After approval, in Xcode: **Settings → Accounts → Manage Certificates → +** → **Developer ID Application**
- Note your **Team ID** (10-char alphanumeric, visible in [your account](https://developer.apple.com/account))

### 2. Notary credentials (one-time, stored in Keychain)

Generate an **app-specific password** at [appleid.apple.com](https://appleid.apple.com) (Sign-in → App-specific passwords).

```bash
xcrun notarytool store-credentials AC_PASSWORD \
  --apple-id "your@email" \
  --team-id "YOURTEAMID" \
  --password "app-specific-password-xxxx-xxxx"
```

### 3. Sparkle update tools

```bash
./scripts/setup-sparkle-tools.sh
```

Downloads `tools/sparkle/bin/{generate_keys,sign_update,generate_appcast}` (gitignored).

### 4. Sparkle signing keypair (one-time)

```bash
./tools/sparkle/bin/generate_keys
```

This:
- Creates an EdDSA keypair
- Stores the **private key in your macOS Keychain** (used automatically by `sign_update`)
- Prints the **public key** to stdout

Copy the public key into `project.yml` → `SUPublicEDKey`, run `xcodegen generate`.

**Critical: back up the private key to 1Password.**

```bash
# Print private key + write to a temp file
./tools/sparkle/bin/generate_keys -x ~/notesmap-private-backup.txt

# Open the file, copy contents into a new 1Password "Secure Note" titled
# "NotesMap Sparkle Private Key", then:
rm ~/notesmap-private-backup.txt
```

If you lose this key (Mac dies, Keychain wiped), **you can no longer sign updates**, existing users would have to manually download new builds. Don't skip the backup.

---

## Per-release workflow

### 1. Bump version

In `project.yml`:

```yaml
MARKETING_VERSION: "1.1"          # user-facing
CURRENT_PROJECT_VERSION: "2"      # build number, monotonically increasing
```

Then:

```bash
xcodegen generate
git add project.yml NotesMap/Info.plist
git commit -m "Bump version to 1.1"
git tag -a v1.1.0 -m "v1.1.0"
```

### 2. Build, sign, notarize, package

```bash
DEVELOPMENT_TEAM=YOURTEAMID NOTARY_PROFILE=AC_PASSWORD ./scripts/release.sh
```

Output:
- `release/NotesMap-1.1.dmg`, signed + notarized + stapled DMG
- `release/NotesMap-1.1.appcast-line.txt`, Sparkle signature for the appcast

### 3. Upload DMG to GitHub Release

- Go to **Releases → Draft a new release** on GitHub
- Tag: `v1.1.0` (existing tag from step 1)
- Title: `v1.1.0, short summary`
- Attach `release/NotesMap-1.1.dmg`
- Publish

### 4. Update `appcast.xml`

Open `appcast.xml` and add a new `<item>` at the top of `<channel>`:

```xml
<item>
    <title>Version 1.1</title>
    <pubDate>Wed, 01 May 2026 12:00:00 +0000</pubDate>
    <description><![CDATA[
        <h3>What's new</h3>
        <ul>
            <li>Feature 1</li>
            <li>Bug fix 2</li>
        </ul>
    ]]></description>
    <enclosure
        url="https://github.com/floriankuemmel/notesmap-mac/releases/download/v1.1.0/NotesMap-1.1.dmg"
        sparkle:version="2"
        sparkle:shortVersionString="1.1"
        SPARKLE_SIGNATURE_LINE_FROM_appcast-line.txt
        type="application/octet-stream" />
    <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
</item>
```

Replace `SPARKLE_SIGNATURE_LINE_FROM_appcast-line.txt` with the contents of `release/NotesMap-1.1.appcast-line.txt` (looks like `sparkle:edSignature="..." length="..."`).

`sparkle:version` is the build number (`CURRENT_PROJECT_VERSION`); `sparkle:shortVersionString` is the marketing version.

### 5. Push appcast + tag

```bash
git add appcast.xml
git commit -m "appcast: announce v1.1.0"
git push
git push --tags
```

Sparkle's update check runs daily, within 24h, all v1.0+ users will see the update prompt. They can also manually check via **NotesMap → Check for Updates…**.

---

## Verifying a release

```bash
# Confirm code signing
codesign -dvvv release/build/export/NotesMap.app

# Confirm Gatekeeper acceptance
spctl -a -vvv -t install release/NotesMap-*.dmg

# Confirm appcast is parseable
curl -fsSL https://raw.githubusercontent.com/floriankuemmel/notesmap-mac/main/appcast.xml | xmllint --format -
```

---

## Troubleshooting

**`sign_update` says "could not find private key"**: the private key isn't in your Keychain. Restore from 1Password:

```bash
echo "PASTE_PRIVATE_KEY_FROM_1PASSWORD_HERE" > /tmp/key.txt
./tools/sparkle/bin/generate_keys --import /tmp/key.txt
rm /tmp/key.txt
```

**Notarization fails with "team-id missing"**: re-run `notarytool store-credentials` and double-check the team-id matches what's in your Apple Developer account.

**Sparkle says "Update is improperly signed"**: the public key in `Info.plist` doesn't match the private key used to sign. Either:
- Re-generate keys and update Info.plist (loses ability to update users on old keys), or
- Restore the original private key from 1Password.

**Users on v1.0 don't see v1.1 update**: check `https://raw.githubusercontent.com/floriankuemmel/notesmap-mac/main/appcast.xml` returns the new `<item>` and that `sparkle:shortVersionString` is correctly higher than 1.0.
