#!/bin/bash
# Adapted from github.com/jagajaga/private-quartz-publish
# server-example/quartz/entrypoint.sh, pinned to commit 3687b47a9b04ffb5ebd2740f328b8310251cc99c.
#
# Adaptation: one-shot builds on each content change instead of upstream's
# persistent `quartz build --watch`. Quartz's watch mode keeps its whole
# toolchain (esbuild, TypeScript, Preact SSR, MathJax/KaTeX, sharp) resident
# in memory at all times -- ~550-600MB RSS on this box even fully idle --
# purely so a rebuild after a change is sub-second instead of a ~30-60s cold
# start. For a personal single-note-publish tool where changes are
# infrequent, that trade is backwards: this cuts idle memory to just Caddy
# (~40MB) at the cost of a ~30-60s delay before a publish/unpublish/edit
# goes live. Also calls bootstrap-cli.mjs directly rather than through
# `npx quartz`, for the same reason as before (no supervisor process).
set -e

SCRATCH=/tmp/quartz-out
mkdir -p /site "$SCRATCH"

# A one-shot `quartz build` (no --watch) cleans its own output directory
# before every run, so removed/rotated pages can never strand stale HTML the
# way upstream's --watch-mode comment warns about -- no sweep step needed
# here, unlike the persistent-watch version this replaces.
#
# Post-process: enforce browser-side lazy behavior on media tags, and inject
# the in-page / folder-scoped find widget. Quartz's HTML pipeline strips these
# attributes even when emitted by the stager, so we re-inject here after Quartz
# writes and before the rsync to /site.
#
#   loading="lazy"  — defers fetch until the element is near the viewport
#                     (works on <img>; ignored on <video>/<audio> but harmless)
#   preload="none"  — video/audio: don't fetch the file until the user
#                     presses play. (Default would fetch metadata + a
#                     chunk; "none" suppresses that.)
postprocess_lazy() {
  cp /pf-find.js "$SCRATCH/pf-find.js" 2>/dev/null || true
  node -e '
    const fs = require("fs");
    const path = require("path");
    const SCRATCH = "'"$SCRATCH"'";
    const TAG = "<script src=\"/pf-find.js\" defer></script>";
    function walk(dir) {
      for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) { walk(p); continue; }
        if (!e.name.endsWith(".html")) continue;
        let s = fs.readFileSync(p, "utf8");
        const orig = s;
        s = s.replace(/<(img|video|audio)(?![^>]*\bloading=)/g, "<$1 loading=\"lazy\"");
        s = s.replace(/<(video|audio)(?![^>]*\bpreload=)/g, "<$1 preload=\"none\"");
        if (!s.includes("/pf-find.js")) {
          if (s.includes("</body>")) s = s.replace("</body>", TAG + "</body>");
          else s += TAG;
        }
        if (s !== orig) fs.writeFileSync(p, s);
      }
    }
    walk(SCRATCH);
  ' 2>/dev/null || true
}

clear_site_if_content_empty() {
  if [ -z "$(ls -A /quartz/content 2>/dev/null)" ]; then
    find /site -mindepth 1 -delete 2>/dev/null || true
    find "$SCRATCH" -mindepth 1 -delete 2>/dev/null || true
  fi
}

# ── Background: mark $DIRTY on any content change ──
# Runs continuously, including while a build is in progress, so a change
# made mid-build is never lost -- the main loop below just compares $DIRTY's
# mtime against the content-state it last built from, once its current
# build finishes.
DIRTY=/tmp/quartz-dirty
touch "$DIRTY"
(
  while true; do
    inotifywait -r -q -e close_write,create,delete,moved_to \
      /quartz/content --timeout 120 2>/dev/null || true
    touch "$DIRTY"
  done
) &

# ── Main supervisor: one-shot build per (debounced) change ──
last_built=""
while true; do
  if [ -z "$(ls -A /quartz/content 2>/dev/null)" ]; then
    clear_site_if_content_empty
    last_built=""
    echo "[quartz] Content empty — waiting for first file to appear..."
    inotifywait -q -e create,moved_to /quartz/content --timeout 300 2>/dev/null || true
    continue
  fi

  dirty_at=$(stat -c %Y "$DIRTY" 2>/dev/null || echo 0)
  if [ "$dirty_at" = "$last_built" ]; then
    # Nothing changed since our last build — block cheaply until something does.
    sleep 2
    continue
  fi

  # Debounce: wait for a quiet second so a burst of writes (e.g. publishing a
  # multi-file folder bundle) settles into one rebuild instead of several.
  sleep 1
  settled_at=$(stat -c %Y "$DIRTY" 2>/dev/null || echo 0)
  if [ "$settled_at" != "$dirty_at" ]; then
    continue # more writes arrived during the debounce window; wait for another
  fi

  echo "[quartz] Building (one-shot; ~30-60s cold start is expected)"
  node --no-deprecation ./quartz/bootstrap-cli.mjs build --output "$SCRATCH" 2>&1 || \
    echo "[quartz] build failed; will retry on next change"
  postprocess_lazy
  rsync -a --delete "$SCRATCH"/ /site/ 2>/dev/null || true
  last_built="$settled_at"
  echo "[quartz] build complete"
done
