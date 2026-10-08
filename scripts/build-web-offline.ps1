# Builds the web app for OFFLINE hosting (e.g. IIS) with CanvasKit + fonts served
# locally, never from a CDN. Output: build/web/  -- deploy this WHOLE folder.
#
# Does a clean build on purpose: incremental builds have been observed to drop the
# useLocalCanvasKit flag from flutter_bootstrap.js, which silently re-enables the
# gstatic CDN. We verify the flag is present before declaring success.
#
# ============================================================================
#  PER-CLIENT CHECKLIST  (do this on the client/<name> branch BEFORE building)
#  The preflight below checks the items marked [auto] and stops if one fails.
# ============================================================================
#  [ ] 1. Branch is client/<name>  (e.g. client/ramen-ibuki). <name> becomes the
#         CLIENT_ID, which clears the previous store's login on the phone.
#         Or pass it explicitly:  -Client ramen-ibuki
#  [auto] 2. .env points at THIS store's Supabase / store settings.
#  [auto] 3. Images in assets/images/ are named <name_with_underscores>_*.jpg|png:
#         <name>.jpg          background  (welcome, table, pin login, qr pages)
#         <name>_logo.jpg     logo        (welcome, table, pin login, order summary)
#         <name>_menubg.jpg   menu hero   (menu_page.dart _heroImage)
#         Every assets/images/ path used in lib/ and web/index.html must exist
#         and contain the client name (no leftover images from another store).
#         Shared generic images are allow-listed in $sharedImages below.
#  [auto] 4. web/index.html splash <img src="assets/assets/images/<name>_logo.jpg">
#  [ ] 5. web/index.html splash colours (#121212 background, #C5A880 accent)
#  [auto] 6. web/index.html <title> and apple-mobile-web-app-title = store name
#         (not "web_table_ordering").
#  [ ] 7. web/manifest.json name / short_name / theme_color; web/favicon.png and
#         web/icons/*  (only shown if a guest does "Add to Home Screen").
#  [ ] 8. Theme colours in the Dart pages, if this client uses a different palette.
# ============================================================================

param(
    # Client/store name. Defaults to the <name> in a "client/<name>" git branch.
    [string]$Client
)

$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

if (-not $Client) {
    $branch = (git rev-parse --abbrev-ref HEAD).Trim()
    if ($branch -match '^client/(.+)$') { $Client = $Matches[1] } else { $Client = $branch }
}
$Client = $Client -replace '[^A-Za-z0-9_-]', '-'
$BuildId = "$Client-$(Get-Date -Format yyyyMMddHHmmss)"
Write-Host "Client: $Client  BuildId: $BuildId" -ForegroundColor Cyan

# --- preflight: catch another store's branding before a 5-minute build ---
$problems = @()
$warnings = @()
$assetKey = $Client -replace '-', '_'
# Generic images every client shares -- not client branding.
$sharedImages = @('assets/images/404.jpg', 'assets/images/logo.jpg')

if (-not (Test-Path ".env")) { $problems += ".env is missing (checklist #2)." }

$refs = Get-ChildItem -Path lib, web/index.html -Recurse -Include *.dart, *.html |
    Select-String -Pattern 'assets/images/[A-Za-z0-9_.-]+' -AllMatches |
    ForEach-Object { $_.Matches.Value } | Sort-Object -Unique
foreach ($r in $refs) {
    if (-not (Test-Path $r)) { $problems += "Missing image: $r (checklist #3)" }
    elseif ($sharedImages -notcontains $r -and $r -notmatch [regex]::Escape($assetKey)) { $warnings += "Image does not look like '$assetKey': $r (checklist #3)" }
}

$index = Get-Content web/index.html -Raw
if ($index -notmatch "splash-logo`" src=`"assets/assets/images/$([regex]::Escape($assetKey))") {
    $problems += "web/index.html splash logo is not a $assetKey image (checklist #4)."
}
if ($index -match '<title>web_table_ordering</title>|apple-mobile-web-app-title" content="web_table_ordering"') {
    $warnings += "web/index.html title is still 'web_table_ordering' (checklist #6)."
}
if ((Get-Content web/manifest.json -Raw) -match '"name": "web_table_ordering"') {
    $warnings += "web/manifest.json name is still the default (checklist #7)."
}

foreach ($w in $warnings) { Write-Warning $w }
if ($problems.Count) {
    $problems | ForEach-Object { Write-Host "  X $_" -ForegroundColor Red }
    Write-Error "Preflight failed -- fix the items above (see checklist at top of this script)."
    exit 1
}
Write-Host "Preflight OK. Manual items still to eyeball: #5 splash colours, #7 icons, #8 theme." -ForegroundColor Green

Write-Host "Cleaning..." -ForegroundColor Cyan
flutter clean | Out-Null
flutter pub get | Out-Null

# --dart-define-from-file=.env compiles the config INTO main.dart.js so the app
#   does not depend on IIS serving the .env asset at runtime.
# --pwa-strategy=none disables the Flutter service worker. On a LAN/IIS deploy
#   the offline PWA cache isn't needed and it repeatedly served STALE builds
#   (old CanvasKit-from-CDN bootstrap) after redeploys. No SW = always fresh.
Write-Host "Building web (offline, local CanvasKit, compiled-in config, no service worker)..." -ForegroundColor Cyan
flutter build web --release --no-web-resources-cdn --dart-define-from-file=.env --pwa-strategy=none --dart-define=CLIENT_ID=$Client
if ($LASTEXITCODE -ne 0) { Write-Error "flutter build failed."; exit 1 }

# --- cache-bust: every store shares one LAN IP/origin, so stamp the entry
#     scripts with a per-client build id the browser has never seen before ---
$indexPath = "build/web/index.html"
(Get-Content $indexPath -Raw) -replace '__BUILD_ID__', $BuildId | Set-Content $indexPath -Encoding utf8 -NoNewline
$bootstrapPath = "build/web/flutter_bootstrap.js"
(Get-Content $bootstrapPath -Raw) -replace '"main\.dart\.js"', "`"main.dart.js?v=$BuildId`"" | Set-Content $bootstrapPath -Encoding utf8 -NoNewline
$versionPath = "build/web/version.json"
if (Test-Path $versionPath) {
    $v = Get-Content $versionPath -Raw | ConvertFrom-Json
    $v | Add-Member -NotePropertyName client -NotePropertyValue $Client -Force
    $v | Add-Member -NotePropertyName build_id -NotePropertyValue $BuildId -Force
    $v | ConvertTo-Json | Set-Content $versionPath -Encoding utf8
}

# --- verify the build is actually offline-safe ---
$bootstrap = "build/web/flutter_bootstrap.js"
$hasLocalFlag = Select-String -Path $bootstrap -Pattern 'useLocalCanvasKit":true' -Quiet
$hasCanvasKit = (Test-Path "build/web/canvaskit/canvaskit.js") -and (Test-Path "build/web/canvaskit/canvaskit.wasm")
$hasWebConfig = Test-Path "build/web/web.config"

if (-not $hasLocalFlag) {
    Write-Error "useLocalCanvasKit flag MISSING from $bootstrap -- build would use the gstatic CDN. Aborting."
    exit 1
}
if (-not (Select-String -Path "build/web/index.html" -Pattern "flutter_bootstrap.js\?v=$BuildId" -Quiet)) {
    Write-Error "index.html cache-bust stamp missing. Aborting."
    exit 1
}
if (-not (Select-String -Path $bootstrap -Pattern "main.dart.js\?v=$BuildId" -Quiet)) {
    Write-Error "main.dart.js cache-bust stamp missing from $bootstrap. Aborting."
    exit 1
}
if ($hasWebConfig -and -not (Select-String -Path "build/web/web.config" -Pattern 'Cache-Control' -Quiet)) {
    Write-Error "web.config has no Cache-Control headers -- stores would share stale caches. Aborting."
    exit 1
}
if (-not $hasCanvasKit) {
    Write-Error "CanvasKit files missing from build/web/canvaskit/. Aborting."
    exit 1
}

Write-Host "OK: useLocalCanvasKit=true, CanvasKit bundled locally." -ForegroundColor Green
if ($hasWebConfig) { Write-Host "OK: web.config present (IIS MIME types + SPA routing)." -ForegroundColor Green }
else { Write-Warning "web.config not found in build output -- IIS will 404 on .wasm." }

Write-Host ""
Write-Host "Deploy the ENTIRE build/web/ folder to IIS (incl. canvaskit/ and web.config)." -ForegroundColor Green
Write-Host "Then hard-refresh / clear the service worker on any machine that saw the old build." -ForegroundColor Yellow
