param([string]$Stage = 'baseline')
$ErrorActionPreference = 'Stop'
$rootDir = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$java = 'C:\Users\Administrator\Documents\Codex\2026-09-25\https-github-com-clash-verge-rev\work\tools\jdk\jdk-21.0.12.1+1\bin\java.exe'
$gradleLib = 'C:\Users\Administrator\.gradle\wrapper\dists\gradle-9.8.0-all\3ofnelc0yuol6b30w7b81vlq3\gradle-9.8.0\lib'
$outputDir = Join-Path $rootDir ".dart_tool/xclient-update-confirmation/$Stage"
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
$source = Get-Content -LiteralPath (Join-Path $rootDir 'android/app/src/main/kotlin/com/follow/clash/xclient/UpdatePlugin.kt') -Raw
$companion = $source.IndexOf('    companion object {')
$receiver = $source.IndexOf('class UpdateInstallReceiver')
if ($companion -lt 0 -or $receiver -lt $companion) { throw 'UpdatePlugin fixture anchors changed' }
$prefix = @'
package com.follow.clash.xclient.fixture
class UpdatePlugin {
    private var binding: Binding? = null
    fun attachForFixture(activity: Activity) { binding = Binding(activity); active = this }
    private fun notifyStatus(sessionId: Int, status: String) { Delivery.statuses += sessionId to status }
'@
$generated = Join-Path $outputDir 'ActualConfirmation.kt'
[IO.File]::WriteAllText($generated, "$prefix`n" + $source.Substring($companion))
$classpath = @((Join-Path $gradleLib 'kotlin-stdlib-2.4.10.jar'),(Join-Path $gradleLib 'annotations-24.0.1.jar')) -join ';'
$log = Join-Path $rootDir "docs/handoff/codex-android-confirmation-$Stage-20261104.log"
& $java -cp "$gradleLib/*" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -nowarn -no-stdlib -no-reflect -jvm-target 17 -classpath $classpath -d $outputDir (Join-Path $PSScriptRoot 'Fixture.kt') $generated 2>&1 | Tee-Object -FilePath $log
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $java -cp "$outputDir;$classpath" com.follow.clash.xclient.fixture.FixtureKt 2>&1 | Tee-Object -FilePath $log -Append
exit $LASTEXITCODE
