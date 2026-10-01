# build-zip.ps1 - package this module tree into dist/AxionRecents-v<version>.zip
#
# Why a script instead of "just zip the folder":
#   * The flashable zip must contain system/product/overlay/AxionRecentsOverlay.apk.
#     post-fs-data.sh looks for exactly that path (RRO_SRC, 8339 bytes) when it stages
#     the RRO; a zip flashed from the KernelSU manager is extracted as-is, so the file
#     has to be inside it.  The repo deliberately does not track system/, hence the
#     staging copy below.
#   * Entry names must use forward slashes.  Compress-Archive emits "payload\X.apk" on
#     Windows, but the Android-side unzip in the installer expects ZIP-spec names, so
#     the entries are written by hand through ZipArchive.
#   * extras/ carries what the C-lite mode needs but the module cannot install itself:
#     the companion LSPosed bridge APK (built by helper/build-helper.ps1, tracked in the
#     repo so CI ships the same binary) and the C-LITE.md install guide.  After flashing,
#     they live in /data/adb/modules/axion_recents/extras/.
#
# Usage:  pwsh -File tools/build-zip.ps1
# Output: dist/AxionRecents-v<version>.zip (size + SHA-256 printed)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = Split-Path -Parent $PSScriptRoot          # the module tree
$dist = Join-Path $root 'dist'

if (-not (Test-Path (Join-Path $root 'module.prop'))) {
    throw "module.prop not found under $root - run this from the module tree"
}

# version comes from module.prop so the file name can never drift from the module
$version = (Select-String -Path (Join-Path $root 'module.prop') -Pattern '^version=(.+)$').Matches[0].Groups[1].Value.Trim()
if (-not $version) { throw 'no version= line in module.prop' }

$stage = Join-Path ([System.IO.Path]::GetTempPath()) "axion-zip-stage-$version"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Path (Join-Path $stage 'payload') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $stage 'system/product/overlay') -Force | Out-Null

# Root scripts + module.prop: everything the manager needs at the top level.
foreach ($f in 'module.prop', 'customize.sh', 'post-fs-data.sh', 'service.sh', 'boot-completed.sh') {
    Copy-Item (Join-Path $root $f) (Join-Path $stage $f) -Force
}

# payload/: what the scripts stage into the tmpfs mirrors at boot.
Get-ChildItem (Join-Path $root 'payload') -File | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $stage 'payload') -Force
}

# system/product/overlay/: the magic-mount source for the static RRO.
Copy-Item (Join-Path $root 'payload/AxionRecentsOverlay.apk') (Join-Path $stage 'system/product/overlay/AxionRecentsOverlay.apk') -Force

# extras/: companion LSPosed bridge APK (C-lite mode) + its install guide.
# Child paths use forward slashes so the script also runs on the CI runner (Linux pwsh).
$helperApk = Join-Path $root 'helper/dist/motodesktop-helper.apk'
if (-not (Test-Path $helperApk)) {
    throw "helper/dist/motodesktop-helper.apk is missing - run helper/build-helper.ps1 first (C-lite needs it)"
}
New-Item -ItemType Directory -Path (Join-Path $stage 'extras') -Force | Out-Null
Copy-Item $helperApk (Join-Path $stage 'extras/motodesktop-helper.apk') -Force
Copy-Item (Join-Path $root 'docs/C-LITE.md') (Join-Path $stage 'extras/C-LITE.md') -Force

New-Item -ItemType Directory -Path $dist -Force | Out-Null
$zip = Join-Path $dist "AxionRecents-$version.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }

$fs = [System.IO.File]::Open($zip, [System.IO.FileMode]::Create)
$arch = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($f in (Get-ChildItem $stage -Recurse -File | Sort-Object FullName)) {
        $rel = $f.FullName.Substring($stage.Length + 1).Replace('\', '/')
        $entry = $arch.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = $f.LastWriteTime
        $es = $entry.Open()
        $src = [System.IO.File]::OpenRead($f.FullName)
        try { $src.CopyTo($es) } finally { $src.Dispose(); $es.Dispose() }
    }
} finally {
    $arch.Dispose()
    $fs.Dispose()
}

$item = Get-Item $zip
Write-Host ("built {0}  {1:N0} B  sha256 {2}" -f $item.Name, $item.Length, (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower())

# Self-check: the RRO must be present at the path post-fs-data.sh verifies, every entry
# name must be forward-slashed, and every file the scripts need must be in there.
$z = [System.IO.Compression.ZipFile]::OpenRead($zip)
try {
    foreach ($e in $z.Entries) {
        if ($e.FullName.Contains('\')) { throw "backslash in entry name: $($e.FullName)" }
    }
    $rro = $z.Entries | Where-Object { $_.FullName -eq 'system/product/overlay/AxionRecentsOverlay.apk' }
    if (-not $rro) { throw 'system/product/overlay/AxionRecentsOverlay.apk missing from the zip' }
    if ($rro.Length -ne 8339) { throw "RRO is $($rro.Length) bytes, post-fs-data.sh expects 8339" }
    foreach ($need in 'module.prop', 'customize.sh', 'post-fs-data.sh', 'service.sh', 'boot-completed.sh',
                      'payload/AxionLauncher3.apk', 'payload/AxionRecentsOverlay.apk',
                      'payload/privapp-permissions-com.android.launcher3.xml',
                      'extras/motodesktop-helper.apk', 'extras/C-LITE.md') {
        if (-not ($z.Entries | Where-Object { $_.FullName -eq $need })) { throw "$need missing from the zip" }
    }
    $helper = $z.Entries | Where-Object { $_.FullName -eq 'extras/motodesktop-helper.apk' }
    if ($helper.Length -ne (Get-Item $helperApk).Length) { throw 'extras/motodesktop-helper.apk is not the built helper' }
    Write-Host ("checked {0} entries, RRO present at {1} bytes, helper {2} bytes" -f $z.Entries.Count, $rro.Length, $helper.Length)
} finally {
    $z.Dispose()
}
