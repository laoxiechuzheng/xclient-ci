# Signed client updates

The update manager consumes a verified policy and an independently signed release document. Before platform installation, the download must match the release document's brand, version, size and SHA-256. URL fallbacks never relax those checks. Partial or mismatched downloads are discarded; another attempt starts from zero.

Normal notices are limited to once per version in 24 hours after the UI calls `noticeShown`. A forced update keeps connections gated while downloading, awaiting permission, failing or falling back to manual installation. Account, purchase and ticket pages remain available. Mount the update host at application startup so this behavior does not depend on opening the update page.

Version comparison uses semantic-version precedence first. Build numbers break a tie only when both versions specify one; a policy naming `1.2.0` therefore treats every `1.2.0` build as current. An explicit build argument overrides a `+build` suffix.

## Installer boundary

`XcPlatformInstaller` receives a file already verified against the signed release document. `preparing` covers unpacking, signature checks and handoff; `awaitingUser` means Android's system confirmation is visible. `manual` means the verified package or download page was opened for the user to finish installation. A detached helper may report `exiting` before the new process starts.

On Android, installation uses PackageInstaller through the `xclient/update` channel. Native code checks the archive's package name and signing certificate before committing. Unknown-app permission and install confirmation remain controlled by Android. `requestInstallPermission` resumes after the per-app settings screen and reports the resulting permission. Android may terminate the old app during replacement before it observes a successful installation result.

## Windows handoff

The detached PowerShell helper waits up to 60 seconds for this process to exit, allowing FlClash to stop its core and clear its system proxy first. It then runs the per-machine Inno installer with silent switches and UAC elevation. The helper relaunches the app after installation failure or a refused UAC prompt, allowing the old version to return.

Inno's Run entry is `skipifsilent`; the non-elevated helper performs the relaunch so the application does not inherit the installer's administrator token. `-EncodedCommand` carries base64 of UTF-16LE to avoid quoting changes between Dart, CreateProcess and PowerShell.

## macOS replacement and limits

The verified zip is extracted with `ditto` to a staging directory beside the installed bundle. Keeping both on the same volume permits a rename-based swap. `codesign --verify --deep --strict` checks the extracted bundle's integrity. Certificate-signed replacements must preserve the bundle identifier, team and certificate Authority chain.

Ad-hoc builds must retain the same bundle identifier and remain ad-hoc. They have no stable signer identity, and their cdhash changes between versions; comparing cdhash values would reject valid updates. Authenticity instead depends on the independently signed release document and its checked SHA-256. This does not provide Developer ID notarization or remove macOS's first-launch restrictions.

After the old process exits, the detached script moves the old bundle aside, installs the new bundle, removes quarantine and asks `open` to launch it. A failed move or failed `open` command restores and reopens the old bundle. This rollback does not detect a later runtime crash after `open` succeeds.

An unsigned development build, an unwritable bundle directory or App Translocation falls back to showing the verified zip in Finder and opening the configured download page. Replacing a read-only translocated copy would not update the installed application.
