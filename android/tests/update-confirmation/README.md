# Update confirmation contract fixture

Run from the repository root on the current Windows workstation:

```powershell
& .\android\tests\update-confirmation\run.ps1 -Stage green
& .\android\tests\update-confirmation\compile.ps1
```

`run.ps1` extracts the actual UpdatePlugin companion and UpdateInstallReceiver bodies into an isolated JVM wrapper. Fixture.kt supplies a simulated Android notification/PendingIntent registry: its tokens remain while application static state is explicitly cleared. It checks payload preservation, per-session token/notification identity, ownership/source refusals, immediate foreground confirmation and terminal cleanup. It does not retain the application's static confirmation as a fake substitute for a system token.

The fixture uses the workstation's already installed JDK and Gradle-distribution Kotlin jars; it installs no dependencies and never invokes a real PackageInstaller. The paths in the scripts are workstation-specific. This directory is outside the app module's `../tests/app` source set, so the default Gradle unit-test task does not run it. Do not report it as an Android device test or a CI test unless the command has actually been run there.

`compile.ps1` compiles the full real UpdatePlugin.kt and receiver against the installed Android API35 android.jar and Flutter embedding. It validates their actual Android API types, not lifecycle or UI behavior. Shipping API37 app compilation, actual notification permission, process death and system installation confirmation remain CI/emulator/device checks.

Generated classes/source stay under `.dart_tool/xclient-update-confirmation/`; safe logs go under ignored `docs/handoff/`. No app, VPN, account, production service or installer is launched.
