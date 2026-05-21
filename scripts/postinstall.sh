#!/bin/bash
#
# postinstall.sh — Quick Markdown installer postinstall script
#
# Behaviour:
#   - If Quick Markdown is currently running for the active console user,
#     quit it (gracefully, then force-kill as a fallback) and re-launch
#     the freshly installed copy in the user's GUI session.
#   - If Quick Markdown is NOT running, do nothing.
#
# Runs as root — the macOS Installer always elevates postinstall scripts.
# Anything that touches the GUI session is dispatched via
# `launchctl asuser <uid> …` so windows open on the user's screen, not as
# root.
#
# Wiring into the .pkg:
#   `pkgbuild` only auto-runs scripts named *exactly* `preinstall` or
#   `postinstall` (no extension) inside the directory passed to
#   `--scripts`. Copy or symlink this file as `postinstall` when
#   assembling the package, e.g.
#
#     mkdir -p build/scripts
#     cp scripts/postinstall.sh build/scripts/postinstall
#     chmod +x build/scripts/postinstall
#     pkgbuild --root … --scripts build/scripts …
#
# See RELEASING.md for the full build pipeline.

set -u

APP_PATH="/Applications/Quick Markdown.app"
APP_BINARY="$APP_PATH/Contents/MacOS/Quick Markdown"
# Must match `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`. If you ever
# rebrand the bundle ID, update both — the AppleScript `tell application
# id` below will silently fail to find the running app otherwise, and the
# graceful-quit path falls through to the `pkill -9` fallback.
BUNDLE_ID="com.neiljohn.quickmarkdown"

# --- Resolve the active GUI user ---------------------------------------------
# /dev/console is owned by whichever user owns the foreground Aqua session.
# If nobody is logged in graphically (e.g. headless MDM install during
# setup) it's owned by root — in which case we have nothing to do.
CONSOLE_USER="$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || echo "")"
if [ -z "$CONSOLE_USER" ] || [ "$CONSOLE_USER" = "root" ]; then
    exit 0
fi

CONSOLE_UID="$(/usr/bin/id -u "$CONSOLE_USER" 2>/dev/null || echo "")"
if [ -z "$CONSOLE_UID" ]; then
    exit 0
fi

# --- Is the old app actually running for that user? --------------------------
# pgrep -U restricts to the user, -f matches against the full command line,
# -- ends option processing in case the path ever contains a leading dash.
if ! /usr/bin/pgrep -U "$CONSOLE_UID" -f -- "$APP_BINARY" >/dev/null 2>&1; then
    exit 0
fi

# --- Ask nicely --------------------------------------------------------------
# Use the bundle ID rather than the app name so a localised Finder name
# can't trip us up. AppleScript runs in the user's GUI session, so the
# app's normal "applicationShouldTerminate" path is invoked. With autosave
# in place from 1.0.4 onwards the app should quit silently without any
# modal sheet, but the longer grace window below covers slow disks and
# (for users still on 1.0.3 or earlier) a save-changes dialog that needs
# a human to dismiss it.
/bin/launchctl asuser "$CONSOLE_UID" \
    /usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" \
    >/dev/null 2>&1 || true

# Wait up to ~20 seconds for the graceful quit to complete.
for _ in $(/usr/bin/seq 1 20); do
    if ! /usr/bin/pgrep -U "$CONSOLE_UID" -f -- "$APP_BINARY" >/dev/null 2>&1; then
        break
    fi
    /bin/sleep 1
done

# --- Force-kill anything still hanging on ------------------------------------
if /usr/bin/pgrep -U "$CONSOLE_UID" -f -- "$APP_BINARY" >/dev/null 2>&1; then
    /usr/bin/pkill -9 -U "$CONSOLE_UID" -f -- "$APP_BINARY" >/dev/null 2>&1 || true
    /bin/sleep 1
fi

# --- Relaunch the freshly installed copy in the user's GUI session ----------
/bin/launchctl asuser "$CONSOLE_UID" /usr/bin/open "$APP_PATH"

exit 0
