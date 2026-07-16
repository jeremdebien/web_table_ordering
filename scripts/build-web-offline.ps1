# Builds the web app for OFFLINE hosting (e.g. IIS) with CanvasKit + fonts served
# locally, never from a CDN. Output: build/web/  -- deploy this WHOLE folder.
#
# Does a clean build on purpose: incremental builds have been observed to drop the
# useLocalCanvasKit flag from flutter_bootstrap.js, which silently re-enables the
# gstatic CDN. We verify the flag is present before declaring success.

$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

Write-Host "Cleaning..." -ForegroundColor Cyan
flutter clean | Out-Null
flutter pub get | Out-Null

# --dart-define-from-file=.env compiles the config INTO main.dart.js so the app
# does not depend on IIS serving the .env asset at runtime.
Write-Host "Building web (offline, local CanvasKit, compiled-in config)..." -ForegroundColor Cyan
flutter build web --release --no-web-resources-cdn --dart-define-from-file=.env

# --- verify the build is actually offline-safe ---
$bootstrap = "build/web/flutter_bootstrap.js"
$hasLocalFlag = Select-String -Path $bootstrap -Pattern 'useLocalCanvasKit":true' -Quiet
$hasCanvasKit = (Test-Path "build/web/canvaskit/canvaskit.js") -and (Test-Path "build/web/canvaskit/canvaskit.wasm")
$hasWebConfig = Test-Path "build/web/web.config"

if (-not $hasLocalFlag) {
    Write-Error "useLocalCanvasKit flag MISSING from $bootstrap -- build would use the gstatic CDN. Aborting."
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
