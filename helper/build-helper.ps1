# build-helper.ps1 - build + sign helper/dist/motodesktop-helper.apk (the LSPosed bridge
# module used by the C-lite mode: stock Moto launcher keeps HOME, Axion serves recents).
#
# Why not Gradle: the module is one class plus a string-array, so the SDK command line tools
# are used directly (aapt2 -> javac -> d8 -> inject classes.dex -> zipalign -> apksigner).
#
# Usage:
#   pwsh -File helper\build-helper.ps1 -SdkRoot "$env:ANDROID_SDK_ROOT" -JdkHome "$env:JAVA_HOME"
#   pwsh -File helper\build-helper.ps1                 # falls back to ANDROID_SDK_ROOT / JAVA_HOME
# Output:
#   helper/dist/motodesktop-helper.apk  (size + SHA-256 printed)
#
# The APK is signed with helper/keystore/axion-moto.jks so that rebuilding it stays
# upgrade-installable over an already installed copy (same signer).

param(
    [string]$SdkRoot = $env:ANDROID_SDK_ROOT,
    [string]$BuildTools = '',
    [string]$JdkHome = $env:JAVA_HOME,
    [string]$Src = '',
    [string]$Dist = ''
)

$ErrorActionPreference = 'Stop'

if (-not $Src) { $Src = $PSScriptRoot }
if (-not $Dist) { $Dist = Join-Path $Src 'dist' }
if (-not $SdkRoot) { $SdkRoot = $env:ANDROID_HOME }
if (-not $SdkRoot) { throw 'no SDK root: pass -SdkRoot or set ANDROID_SDK_ROOT / ANDROID_HOME' }
if (-not $JdkHome) { throw 'no JDK: pass -JdkHome or set JAVA_HOME' }

# The bridge version lives in helper.prop, NOT in ../module.prop.
#
# Why decoupled (v1.2.2): every `pm install` of the bridge gives the APK a brand new
# /data/app/~~<random>/... path. LSPosed remembers the path it first loaded in
# /data/adb/lspd/config/modules_config.db; once that path is gone it silently skips the module,
# so C-lite stops working without any error. A release that only edits the module scripts must
# therefore NOT rebuild/reinstall the bridge - its version (and the bytes it produces) stay put.
# Bump version/versionCode here only when Main.java / assets / res actually change.
$versionCode = '1'
$versionName = '1.0'
$helperProp = Join-Path $Src 'helper.prop'
$modProp = Join-Path (Split-Path $Src -Parent) 'module.prop'
if (Test-Path $helperProp) {
    $hp = Get-Content $helperProp -Raw
    if ($hp -match '(?m)^versionCode=(\S+)') { $versionCode = $Matches[1].Trim() }
    if ($hp -match '(?m)^version=(\S+)') { $versionName = $Matches[1].Trim().TrimStart('v') }
    Write-Host "== version   : $versionName ($versionCode)  [helper.prop]"
} elseif (Test-Path $modProp) {
    Write-Warning "no helper.prop next to $Src - falling back to module.prop (the bridge would then follow every module release)"
    $mp = Get-Content $modProp -Raw
    if ($mp -match '(?m)^versionCode=(\S+)') { $versionCode = $Matches[1].Trim() }
    if ($mp -match '(?m)^version=(\S+)') { $versionName = $Matches[1].Trim().TrimStart('v') }
    Write-Host "== version   : $versionName ($versionCode)  [module.prop fallback]"
} else {
    Write-Warning "neither helper.prop nor module.prop next to $Src - keeping version $versionName ($versionCode)"
    Write-Host "== version   : $versionName ($versionCode)"
}

if (-not $BuildTools) {
    $btRoot = Join-Path $SdkRoot 'build-tools'
    if (-not (Test-Path $btRoot)) { throw "no build-tools under $SdkRoot" }
    $BuildTools = (Get-ChildItem $btRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
}
$bt = Join-Path $SdkRoot (Join-Path 'build-tools' $BuildTools)
$androidJar = (Get-ChildItem (Join-Path $SdkRoot 'platforms') -Directory |
        Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'android.jar' } |
        Where-Object { Test-Path $_ } | Select-Object -First 1)
if (-not $androidJar) { throw "no android.jar under $SdkRoot\platforms" }

$env:JAVA_HOME = $JdkHome
$env:PATH = (Join-Path $JdkHome 'bin') + ';' + $env:PATH
Write-Host "== sdk       : $bt"
Write-Host "== android.jar: $androidJar"
Write-Host "== jdk       : $JdkHome"

$work = Join-Path $Src 'build'
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
foreach ($d in @($work, (Join-Path $work 'classes'), (Join-Path $work 'dex'), $Dist)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

function Invoke-Strict {
    param([string]$Name, [scriptblock]$Body)
    Write-Host "== $Name"
    & $Body
    if ($LASTEXITCODE -ne 0) { throw "$Name failed with exit code $LASTEXITCODE" }
}

$resZip = Join-Path $work 'res.zip'
$baseApk = Join-Path $work 'base.apk'
$classesDir = Join-Path $work 'classes'
$dexDir = Join-Path $work 'dex'
$stubJar = Join-Path $work 'stubs.jar'
$moduleJar = Join-Path $work 'module.jar'

Invoke-Strict 'aapt2 compile' {
    & "$bt\aapt2.exe" compile --dir (Join-Path $Src 'res') -o $resZip
}

Invoke-Strict 'aapt2 link' {
    & "$bt\aapt2.exe" link -o $baseApk -I $androidJar `
        --manifest (Join-Path $Src 'AndroidManifest.xml') `
        -A (Join-Path $Src 'assets') `
        $resZip `
        --java (Join-Path $work 'gen') `
        --min-sdk-version 29 --target-sdk-version 34 `
        --version-code $versionCode --version-name $versionName
}

$srcs = @(Get-ChildItem (Join-Path $Src 'java') -Recurse -Filter *.java | ForEach-Object FullName)
$stubs = @(Get-ChildItem (Join-Path $Src 'stubs') -Recurse -Filter *.java | ForEach-Object FullName)
Write-Host ("== javac (" + $srcs.Count + " module sources, " + $stubs.Count + " compile-only stubs)")
& "$JdkHome\bin\javac.exe" -nowarn -encoding UTF-8 -source 8 -target 8 `
    -cp $androidJar `
    -sourcepath ((Join-Path $Src 'java') + ';' + (Join-Path $Src 'stubs')) `
    -d $classesDir @($srcs + $stubs)
if ($LASTEXITCODE -ne 0) { throw "javac failed with exit code $LASTEXITCODE" }

Invoke-Strict 'jar (module + stubs for d8)' {
    Push-Location $classesDir
    try {
        & "$JdkHome\bin\jar.exe" cf $moduleJar com
        & "$JdkHome\bin\jar.exe" cf $stubJar de
    } finally {
        Pop-Location
    }
}

Invoke-Strict 'd8' {
    & "$bt\d8.bat" --release --min-api 29 --lib $androidJar --lib $stubJar `
        --output $dexDir $moduleJar
}

$dex = Join-Path $dexDir 'classes.dex'
if (-not (Test-Path $dex)) { throw 'd8 did not produce classes.dex' }

Write-Host '== inject classes.dex'
$unsigned = Join-Path $work 'unsigned.apk'
Copy-Item $baseApk $unsigned -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::Open($unsigned, [System.IO.Compression.ZipArchiveMode]::Update)
try {
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $dex, 'classes.dex') | Out-Null
} finally {
    $zip.Dispose()
}

$aligned = Join-Path $work 'aligned.apk'
Invoke-Strict 'zipalign' {
    & "$bt\zipalign.exe" -f -p 4 $unsigned $aligned
}

$ks = Join-Path $Src 'keystore\axion-moto.jks'
if (-not (Test-Path $ks)) {
    Write-Host '== keytool (create keystore)'
    New-Item -ItemType Directory -Force -Path (Split-Path $ks) | Out-Null
    & "$JdkHome\bin\keytool.exe" -genkeypair -keystore $ks -alias axionmoto `
        -storepass android -keypass android `
        -dname "CN=Axion Moto Desktop Helper, O=AxionRecents, C=CN" `
        -keyalg RSA -keysize 2048 -validity 10950 -noprompt
    if ($LASTEXITCODE -ne 0) { throw 'keytool failed' }
}

$apk = Join-Path $Dist 'motodesktop-helper.apk'
Invoke-Strict 'apksigner sign' {
    & "$bt\apksigner.bat" sign --ks $ks --ks-pass pass:android --key-pass pass:android `
        --v1-signing-enabled true --v2-signing-enabled true --out $apk $aligned
}

Write-Host '== verify'
& "$bt\apksigner.bat" verify --print-certs $apk
& "$bt\aapt2.exe" dump resources $apk | Select-String -Pattern 'xposedscope|size=2'
$xmltree = & "$bt\aapt2.exe" dump xmltree --file AndroidManifest.xml $apk
$xmltree | Select-String -Pattern 'xposed|versionName|package='

# Authoritative version actually baked into the APK (aapt2), written next to the APK so that
# tools/build-zip.ps1 can ship it as helper.prop inside the module and the on-device scripts
# compare the same numbers the package manager reports.  Reading it back also catches a
# hardcoded android:versionCode/android:versionName in AndroidManifest.xml, which used to
# override the aapt2 --version-code/--version-name flags silently.
$apkVc = $versionCode
$apkVn = $versionName
$tree = $xmltree -join "`n"
$m = [regex]::Match($tree, 'versionCode\(0x0101021b\)=(\d+)')
if ($m.Success) { $apkVc = $m.Groups[1].Value }
$m = [regex]::Match($tree, 'versionName\(0x0101021c\)="([^"]*)"')
if ($m.Success) { $apkVn = $m.Groups[1].Value }
$propOut = Join-Path $Dist 'motodesktop-helper.prop'
# Unix line endings on purpose: the on-device scripts read this with sed and compare the value
# (a stray CR would travel into the comparison).
$propText = @(
    '# generated by helper/build-helper.ps1 - version actually baked into motodesktop-helper.apk.',
    '# tools/build-zip.ps1 ships this as helper.prop inside the module zip; customize.sh and',
    '# service.sh compare the installed versionCode against it before reinstalling the bridge.',
    "version=$apkVn",
    "versionCode=$apkVc",
    ''
) -join "`n"
[System.IO.File]::WriteAllText($propOut, $propText, (New-Object System.Text.ASCIIEncoding))
Write-Host "== helper.prop: version=$apkVn versionCode=$apkVc -> $propOut"
if ($apkVc -ne $versionCode -or $apkVn -ne $versionName) {
    Write-Warning "the APK reports $apkVn ($apkVc) but helper.prop asked for $versionName ($versionCode) - check AndroidManifest.xml"
}

$fi = Get-Item $apk
"APK: $apk"
"SIZE: $($fi.Length)"
"SHA256: $((Get-FileHash $apk -Algorithm SHA256).Hash)"
