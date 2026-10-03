# build-lspd-fix.ps1 - build helper/lspd-fix.jar, the tiny tool service.sh runs through
# app_process to repair the APK path LSPosed has cached for the bridge
# (helper/lspd-fix/com/axion/recents/LspdPathFix.java).
#
# Why a separate jar instead of adding the class to the bridge APK: the bridge APK must not be
# rebuilt/reinstalled outside a real bridge change (every reinstall invalidates the very path this
# tool repairs).  The fixer only has to exist as a dex the module can hand to app_process.
#
# Usage:
#   pwsh -File tools\build-lspd-fix.ps1 -SdkRoot "$env:ANDROID_SDK_ROOT" -JdkHome "$env:JAVA_HOME"
# Output:
#   helper/lspd-fix.jar  (size + SHA-256 printed)

param(
    [string]$SdkRoot = $env:ANDROID_SDK_ROOT,
    [string]$BuildTools = '',
    [string]$JdkHome = $env:JAVA_HOME,
    [string]$Src = '',
    [string]$Out = ''
)

$ErrorActionPreference = 'Stop'

if (-not $Src) { $Src = Join-Path (Split-Path $PSScriptRoot -Parent) 'helper/lspd-fix' }
if (-not $Out) { $Out = Join-Path (Split-Path $PSScriptRoot -Parent) 'helper/lspd-fix.jar' }
if (-not $SdkRoot) { $SdkRoot = $env:ANDROID_HOME }
if (-not $SdkRoot) { throw 'no SDK root: pass -SdkRoot or set ANDROID_SDK_ROOT / ANDROID_HOME' }
if (-not $JdkHome) { throw 'no JDK: pass -JdkHome or set JAVA_HOME' }

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

Write-Host "== sdk        : $bt"
Write-Host "== android.jar: $androidJar"
Write-Host "== jdk        : $JdkHome"

$work = Join-Path $Src 'build'
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
foreach ($d in @($work, (Join-Path $work 'classes'), (Join-Path $work 'dex'))) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

$classesDir = Join-Path $work 'classes'
$dexDir = Join-Path $work 'dex'
$classJar = Join-Path $work 'lspd-fix-classes.jar'

$srcs = @(Get-ChildItem $Src -Recurse -Filter *.java | Where-Object { $_.FullName -notmatch '\\build\\' } | ForEach-Object FullName)
if ($srcs.Count -eq 0) { throw "no .java sources under $Src" }

Write-Host ("== javac (" + $srcs.Count + " source(s))")
& "$JdkHome\bin\javac.exe" -nowarn -encoding UTF-8 -source 8 -target 8 -cp $androidJar -d $classesDir @srcs
if ($LASTEXITCODE -ne 0) { throw "javac failed with exit code $LASTEXITCODE" }

Write-Host '== jar'
Push-Location $classesDir
try {
    & "$JdkHome\bin\jar.exe" cf $classJar com
} finally {
    Pop-Location
}
if ($LASTEXITCODE -ne 0) { throw "jar failed with exit code $LASTEXITCODE" }

Write-Host '== d8'
& "$bt\d8.bat" --release --min-api 29 --lib $androidJar --output $dexDir $classJar
if ($LASTEXITCODE -ne 0) { throw "d8 failed with exit code $LASTEXITCODE" }

# app_process loads the dex straight out of the CLASSPATH entry, so the delivered jar is just a zip
# with classes.dex at its root (that is also how the platform's own am.jar/pm.jar are built).
$dex = Join-Path $dexDir 'classes.dex'
if (-not (Test-Path $dex)) { throw 'd8 did not produce classes.dex' }
if (Test-Path $Out) { Remove-Item $Out -Force }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$fs = [System.IO.File]::Open($Out, [System.IO.FileMode]::Create)
$arch = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    $entry = $arch.CreateEntry('classes.dex', [System.IO.Compression.CompressionLevel]::Optimal)
    $es = $entry.Open()
    $dexStream = [System.IO.File]::OpenRead($dex)
    try { $dexStream.CopyTo($es) } finally { $dexStream.Dispose(); $es.Dispose() }
} finally {
    $arch.Dispose()
    $fs.Dispose()
}

$item = Get-Item $Out
Write-Host ("built {0}  {1:N0} B  sha256 {2}" -f $item.Name, $item.Length, (Get-FileHash $Out -Algorithm SHA256).Hash.ToLower())

# Self-check: classes.dex must be the only entry and the class the scripts call must be in it.
$z = [System.IO.Compression.ZipFile]::OpenRead($Out)
try {
    if ($z.Entries.Count -ne 1 -or $z.Entries[0].FullName -ne 'classes.dex') {
        throw "unexpected entries: $(($z.Entries | ForEach-Object FullName) -join ', ')"
    }
    Write-Host ("checked {0} entry, {1} bytes" -f $z.Entries.Count, $z.Entries[0].Length)
} finally {
    $z.Dispose()
}
