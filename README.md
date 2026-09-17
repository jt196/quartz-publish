# quartz-publish

Self-hosted "publish one Obsidian note at a time behind a private URL",
built on the [Private Quartz Publish](https://github.com/jagajaga/private-quartz-publish)
Obsidian plugin's reference stack, repackaged as two images instead of the
upstream three:

| Image | What it does | Vault access | Exposed ports |
|---|---|---|---|
| `ghcr.io/jt196/quartz-publish-stager` | Deno process. Mirrors only notes with `publish: true` (plus embeds, link-rewritten) into a flat, Docker-internal content volume. | Reads the vault **read-only**. | **None.** No listener, no inbound network. |
| `ghcr.io/jt196/quartz-publish-web` | Quartz v4 build-watch loop + Caddy (static serving only — `try_files` fallback, security headers, custom 404). | **None.** Only ever reads the content volume the stager writes. | `8080` (put a reverse proxy in front for TLS). |

## Why two images, not one

The upstream reference stack is 3 containers (stager, Quartz, Caddy-for-TLS).
Dropping Caddy's TLS/ACME role (a reverse proxy already handles that) still
leaves two components with genuinely different trust levels:

- The **stager** needs to read the whole vault to find `publish: true`
  notes — that's the entire point of "flag any note from Obsidian" instead
  of maintaining a separate public-only folder. It's a small, auditable
  script with no network listener at all.
- **Quartz + its npm dependency tree**, plus the process answering HTTP
  requests from the internet, is comparatively large attack surface. It
  has no reason to ever see the vault, so it doesn't — it only ever reads
  the flat content directory the stager already filtered.

Splitting along that line means a bug or compromise in the internet-facing
side has no filesystem path to unpublished notes, as an OS-level guarantee
rather than something that depends on the stager's code being bug-free.

All of the upstream "stager invariants" and "Quartz config invariants"
(see the plugin's own `server-example/README.md`) still apply — nothing
about the privacy model changed, only which container the two halves run in.

## What's vendored vs. adapted

Straight copies of upstream `server-example/` files, pinned to commit
`3687b47a9b04ffb5ebd2740f328b8310251cc99c` (noted in each file's header):
`stager/main.ts`, `web/pf-find.js`, `web/FolderSidebar.tsx`,
`web/quartz.layout.ts`.

Adapted:
- `web/quartz.config.ts.template` — same as upstream except `baseUrl` and
  `pageTitle` are `envsubst` placeholders, filled in from `PUBLIC_DOMAIN`/
  `PAGE_TITLE` env vars at container start (`web/s6-rc.d/quartz/run`) so the
  domain doesn't have to be baked in at build time.
- `web/Caddyfile` — same `try_files`/headers/error-handling as upstream,
  but serves plain HTTP on `:8080` instead of a domain block with ACME —
  TLS is the reverse proxy's job now, not this container's.
- `web/entrypoint.sh` — same watch/rsync/postprocess loop as upstream,
  except it invokes `bootstrap-cli.mjs` directly instead of `npx quartz`,
  which saves ~90MB RSS by not keeping a second Node.js process resident
  purely as an `npm exec` supervisor (see file header for detail).

To re-sync after an upstream change: diff the pinned commit against
upstream's `server-example/`, re-apply the two adaptations above to
whatever changed, bump the pinned commit in the header comments.

## Building

```bash
docker buildx build --platform linux/amd64,linux/arm64 -t quartz-publish-stager ./stager
docker buildx build --platform linux/amd64,linux/arm64 -t quartz-publish-web ./web
```

CI (`.github/workflows/build.yml`) does this automatically on push to
`main` and on `v*` tags, pushing both images to GHCR tagged `latest`,
the commit sha, and (on a tag push) the semver tag. No secrets needed
beyond the workflow's own `GITHUB_TOKEN`.

## Runtime config (env vars, `web` image)

| Var | Required | Meaning |
|---|---|---|
| `PUBLIC_DOMAIN` | yes | Bare domain notes are served at, e.g. `notes.example.com` (no scheme — this is Quartz's `baseUrl`). |
| `PAGE_TITLE` | no (default `My published notes`) | Site title. |

`stager` env vars (`VAULT_DIR`, `CONTENT_DIR`) are internal container paths,
already set correctly in the deploy compose file — no need to change them.

## Deploying

See the separate `docker-quartz-publish` repo for the actual
`docker-compose.yaml` this NAS runs — this repo only builds the images.
