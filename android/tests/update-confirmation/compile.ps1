$ErrorActionPreference = 'Stop'
$rootDir = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$jdk = 'C:\Users\Administrator\Documents\Codex\2026-09-25\https-github-com-clash-verge-rev\work\tools\jdk\jdk-21.0.12.1+1'
$sdk = 'C:\Users\Administrator\Documents\Codex\2026-09-25\https-github-com-clash-verge-rev\work\tools\android-sdk-root'
$gradleLib = 'C:\Users\Administrator\.gradle\wrapper\dists\gradle-9.8.0-all\3ofnelc0yuol6b30w7b81vlq3\gradle-9.8.0\lib'
$output = Join-Path $rootDir '.dart_tool/xclient-update-confirmation/api35'
New-Item -ItemType Directory -Force -Path $output | Out-Null
$classpath = @(
    (Join-Path $sdk 'platforms/android-35/android.jar'),
    'C:\Users\Administrator\sdk\flutter\bin\cache\artifacts\engine\android-x64\flutter.jar',
    (Join-Path $gradleLib 'kotlin-stdlib-2.4.10.jar'),
    (Join-Path $gradleLib 'annotations-24.0.1.jar')
) -join ';'
& (Join-Path $jdk 'bin/java.exe') -cp "$gradleLib/*" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-stdlib -no-reflect -jvm-target 17 -classpath $classpath -d $output (Join-Path $rootDir 'android/app/src/main/kotlin/com/follow/clash/xclient/UpdatePlugin.kt')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Output 'PASS complete UpdatePlugin.kt + receiver compiled against real Android API35 and Flutter embedding; no installer executed.'
