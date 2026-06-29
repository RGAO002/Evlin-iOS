#!/bin/sh
# Upload Release dSYMs to Sentry so crashes symbolicate to file:line.
#
# Why: the app already generates dSYMs for Release (DEBUG_INFORMATION_FORMAT =
# dwarf-with-dsym) but never uploads them, so app-side stack frames in Sentry
# are raw addresses. Uploading lets Sentry re-symbolicate existing AND future
# events — e.g. the App-Hang issue (EVLIN-IOS-J) will then point at the exact
# SwiftUI view instead of just "_UIHostingView.layoutSubviews".
#
# Wire-up: add this as a "Run Script" build phase (after "Compile Sources"),
# or run it manually after an archive. Safe to keep in CI.
#
# Token: needs a Sentry auth token with the `project:releases` (write) scope.
# The read-only token used to QUERY issues is NOT sufficient. Resolution order:
#   1. env  SENTRY_AUTH_TOKEN
#   2. file $SRCROOT/sentry.env   (untracked — see .gitignore)
# Org/project are not secret and are hardcoded below.
set -eu

SENTRY_ORG="evlin"
SENTRY_PROJECT="evlin-ios"

if [ "${SENTRY_SKIP_DSYM_UPLOAD:-0}" = "1" ]; then
  echo "SENTRY_SKIP_DSYM_UPLOAD=1 - skipping dSYM upload."
  exit 0
fi

# Load the token from the untracked env file if it isn't already exported.
if [ -z "${SENTRY_AUTH_TOKEN:-}" ] && [ -f "${SRCROOT:-.}/sentry.env" ]; then
  # shellcheck disable=SC1091
  . "${SRCROOT:-.}/sentry.env"
fi
if [ -z "${SENTRY_AUTH_TOKEN:-}" ]; then
  echo "warning: SENTRY_AUTH_TOKEN not set — skipping dSYM upload (see scripts/sentry-upload-dsyms.sh header)."
  exit 0
fi
export SENTRY_AUTH_TOKEN SENTRY_ORG SENTRY_PROJECT

# Xcode fills DWARF_DSYM_FOLDER_PATH for the current build/archive. Check this
# FIRST so Debug builds (which produce no dSYM bundle) exit before we ever touch
# the network or install sentry-cli — keeps every incremental build fast.
DSYM_PATH="${DWARF_DSYM_FOLDER_PATH:-}"
if [ -z "$DSYM_PATH" ] || [ ! -d "$DSYM_PATH" ]; then
  echo "no dSYM folder at '${DSYM_PATH:-<unset>}' — nothing to upload (Debug build?)."
  exit 0
fi

# Find sentry-cli, or install a copy into a build-local cache (never global).
CLI="$(command -v sentry-cli || true)"
if [ -z "$CLI" ]; then
  CACHE="${SRCROOT:-.}/.sentry-cli"
  if [ ! -x "$CACHE/sentry-cli" ]; then
    echo "sentry-cli not found — installing into $CACHE"
    curl -sL https://sentry.io/get-cli/ | INSTALL_DIR="$CACHE" bash || {
      echo "warning: sentry-cli install failed — skipping dSYM upload."; exit 0; }
  fi
  CLI="$CACHE/sentry-cli"
fi

echo "Uploading dSYMs from $DSYM_PATH -> $SENTRY_ORG/$SENTRY_PROJECT"
"$CLI" debug-files upload --include-sources --org "$SENTRY_ORG" --project "$SENTRY_PROJECT" "$DSYM_PATH"
