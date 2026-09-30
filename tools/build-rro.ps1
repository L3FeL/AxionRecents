# build-rro.ps1 - compile + sign the static framework RRO shipped in payload/
#
# The RRO does exactly one thing: it overrides android:string/config_recentsComponentName
# to point at this module's launcher.  The stock Motorola overlay
# (/product/overlay/framework-rro-launcher3.apk, package com.motorola.overlay.launcher3,
# priority 1) overrides the same resource, so ours uses priority 100 to win.
#
# The signature only has to be *valid*: a static RRO that is not signed with the target's
# certificate is accepted on this shipping ROM (the stock Moto overlay and framework-res.apk
# are signed with different certificates as well).  The throwaway key lives in
# tools/axion-recents.jks (store/key password: axionrecents) so builds are reproducible.
#
# Requires an Android SDK with build-tools (aapt2, zipalign, apksigner) matching the target
# SDK, plus a JDK for apksigner/keytool.
#
# Usage:
#   pwsh -File tools/build-rro.ps1                       # uses $env:ANDROID_SDK_ROOT / ANDROID_HOME
#   pwsh -File tools/build-rro.ps1 -SdkRoot D:\android-sdk
# Output: payload/AxionRecentsOverlay.apk  (then re-run tools/build-zip.ps1)

[CmdletBinding()]
param(
    [string]$SdkRoot = $(if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { $env:ANDROID_HOME }),
    [string]$BuildTools = '',          # e.g. '36.0.0'; default: newest one found
    [string]$PlatformJar = '',         # e.g. 'android-36/android.jar'; default: newest found
    [string]$KsPass = 'axionrecents',
    [string]$KsAlias = 'axionrecents'
)

$ErrorActionPreference = 'Stop'

if (-not $SdkRoot) { throw 'no Android SDK: pass -SdkRoot or set ANDROID_SDK_ROOT / ANDROID_HOME' }
$root = Split-Path -Parent $PSScriptRoot
$rro  = Join-Path $root 'rro'
$out  = Join-Path $root 'payload'

if (-not $BuildTools) {
    $bt = Join-Path $SdkRoot 'build-tools'
    if (-not (Test-Path $bt)) { throw "build-tools not found under $SdkRoot" }
    $BuildTools = (Get-ChildItem $bt -Directory | Sort-Object { [version]($_.Name -replace '[^0-9.]', '') } | Select-Object -Last 1).Name
}
if (-not $PlatformJar) {
    $pf = Join-Path $SdkRoot 'platforms'
    if (-not (Test-Path $pf)) { throw "platforms not found under $SdkRoot" }
    $p = (Get-ChildItem $pf -Directory | Sort-Object Name | Select-Object -Last 1).FullName
    $PlatformJar = Join-Path $p 'android.jar'
}

$btDir     = Join-Path $SdkRoot "build-tools\$BuildTools"
$aapt2     = Join-Path $btDir 'aapt2.exe'
$zipalign  = Join-Path $btDir 'zipalign.exe'
$apksigner = Join-Path $btDir 'apksigner.bat'
$ks        = Join-Path $root 'tools\axion-recents.jks'
$name      = 'AxionRecentsOverlay.apk'

foreach ($tool in $aapt2, $zipalign, $apksigner) {
    if (-not (Test-Path $tool)) { throw "missing build tool: $tool" }
}
if (-not (Test-Path $PlatformJar)) { throw "missing android.jar: $PlatformJar" }
if (-not (Test-Path $ks)) { throw "missing keystore: $ks" }

New-Item -ItemType Directory -Force -Path $out | Out-Null

# 1. compile resources
$compiled = Join-Path $rro 'compiled.zip'
if (Test-Path $compiled) { Remove-Item $compiled -Force }
& $aapt2 compile --dir (Join-Path $rro 'res') -o $compiled
if ($LASTEXITCODE -ne 0) { throw 'aapt2 compile failed' }

# 2. link
$unsigned = Join-Path $rro "$name.unsigned"
if (Test-Path $unsigned) { Remove-Item $unsigned -Force }
& $aapt2 link -o $unsigned -I $PlatformJar --manifest (Join-Path $rro 'AndroidManifest.xml') $compiled
if ($LASTEXITCODE -ne 0) { throw 'aapt2 link failed' }

# 3. align + sign (v1 off for minSdk 36; v2 + v3 on)
$aligned = Join-Path $rro "$name.aligned"
if (Test-Path $aligned) { Remove-Item $aligned -Force }
& $zipalign -f -p 4 $unsigned $aligned
$final = Join-Path $out $name
if (Test-Path $final) { Remove-Item $final -Force }
& $apksigner sign --ks $ks --ks-pass "pass:$KsPass" --key-pass "pass:$KsPass" `
    --v1-signing-enabled false --v2-signing-enabled true --v3-signing-enabled true `
    --v4-signing-enabled false `
    --out $final $aligned
if ($LASTEXITCODE -ne 0) { throw 'apksigner sign failed' }

Remove-Item $unsigned, $aligned -Force -ErrorAction SilentlyContinue

# 4. report - the size is asserted by post-fs-data.sh (RRO_SRC) and tools/build-zip.ps1
$len = (Get-Item $final).Length
Write-Host "--- built $final ($len B)"
if ($len -ne 8339) {
    Write-Warning "payload RRO is $len bytes but post-fs-data.sh / build-zip.ps1 expect 8339 - update both if the change is intentional"
}
& $apksigner verify --print-certs $final | Select-String 'certificate DN|certificate SHA-256'
& $aapt2 dump resources $final | Select-String 'config_recentsComponentName'
& $aapt2 dump xmltree --file AndroidManifest.xml $final | Select-String 'package=|priority|targetPackage|isStatic|hasCode'
Write-Host '--- now re-run tools/build-zip.ps1 to refresh dist/'
