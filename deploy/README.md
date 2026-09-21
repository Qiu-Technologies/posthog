# PostHog self-hosted deployment (hobby) — owned by this fork

This fork of `PostHog/posthog` exists to put the self-hosted PostHog stack under
git control and deploy it through Forge. Upstream application code is used as-is
(images pulled from the registries); everything deployment-specific lives in
`deploy/`.

> The fork is **public** — GitHub does not allow private forks of public repos.
> Everything under `deploy/` is config only: the real secrets live in the
> vault (`pass posthog/deploy-env`, `pass posthog/env-services`) and on the
> target at `$BOX_DIR/.env*` (0600). Never commit real `.env` files.

**Default branch is `main` while upstream uses `master`** — deliberate: the
Forge controller only runs pipelines for the default branch (`main`), and
deploys should be deliberate anyway. To take an upstream upgrade: fetch
`https://github.com/PostHog/posthog.git`, merge `master` into `main`, resolve,
push — Forge redeploys.

## Target host

The pipeline deploys to a target selected **runner-side**, not in this repo:

- `~/.config/posthog-deploy/env` (0600 on the runner) may set `BOX_SSH`
  (`local` = deploy on the runner host itself; default is the cachy-ssh
  wrapper), `BOX_DIR`, `PROXY_BIND_IP`, `HEALTH_URL`.
- Currently: **stevenspc (local)**, `BOX_DIR=/home/stevens/apps/posthog`,
  proxy on `127.0.0.1:18080` (the tier-0 cloudflared tunnel reaches it
  directly). Serving moved here from the cachyos box on 2026-09-21 because
  the 12GB box was overcommitted (multi-GB swap thrash); stevenspc has 32GB.

## The trim

`deploy/docker-compose.trim.yml` is merged **last** in every compose call. It
gives ten optional/heavy services a `trimmed` profile, which removes them from
a default `up -d` (37 → 27 services, and the heavyweight JVM ones are gone):

- `temporal`, `temporal-django-worker`, `temporal-admin-tools`, `temporal-ui`
  — batch exports and scheduled/background workflows stop running
- `plugins` — the legacy plugin server (deprecated upstream)
- `cymbal`, `cymbal-resolution`, `elasticsearch` — error tracking
- `replay-capture`, `recording-api` — session replay ingestion/API

Nothing that remains depends on them (verified against `depends_on`), so core
analytics — capture, ingestion, ClickHouse, dashboards, feature flags,
persons — is unaffected. To re-enable one: delete its line and push. To run
everything once: `docker compose --profile trimmed up -d`.

## Layout

```
deploy/
  docker-compose.yml        the hobby stack (upstream hobby file as deployed,
                            with the proxy bind parameterized: PROXY_BIND_IP)
  docker-compose.base.yml   upstream base services (extends targets)
  docker-compose.override.yml our override (TLS off behind cloudflared)
  docker-compose.trim.yml   the trim overlay (profiles; merged last)
  .env.example              every key the deploy needs — VALUES ARE PLACEHOLDERS
  scripts/deploy-box.sh     the Forge production step (see below)
  support/                  bind-mounted support dirs that upstream generates
    compose/                start / wait / temporal-django-worker
    docker/postgres-init-scripts/  (empty — the real ones come from the clone)
    products/               (empty dir — the real ones come from the clone)
pipeline.yml                Forge pipeline (root; the controller reads this)
```

## How a deploy works

Push to `main` → Forge webhook → `build` validates the compose files (with the
trim overlay) → `production` runs `deploy/scripts/deploy-box.sh` on the CI
runner (host step):

1. Ships `.env` / `.env.services` from the vault to `$BOX_DIR` (0600).
2. Sparse-clones **this fork** on the target and checks out the pushed SHA
   (`--filter=blob:none`, only `deploy/ products/ docker/ posthog/idl
   posthog/user_scripts` are materialized) — the target always runs the config
   that is in git at the deployed commit. The compose project files are copied
   from `deploy/` to `$BOX_DIR` root, matching the classic hobby layout
   (`./posthog`, `./compose`, `./share`, `./products`, `./docker`, `.env`,
   `.env.services` are all siblings of the compose file).
3. Materializes the support dirs (`compose/` copied; `products` and
   `docker/postgres-init-scripts` symlinked into the clone; `share/` GeoLite
   db shipped from `$HOME/opt/posthog/share` — MaxMind license keeps it out
   of git).
4. Runs `docker compose pull && up -d` **on the target in the background**
   (the images are GBs; the step polls `deploy-run.log`, bounded at ~25 min).
   A failed pull (registry rate limit) does not block — compose runs the
   cached images and the health check remains the gate.
5. Health: polls `$HEALTH_URL` until the web app answers (302 to /login).

The pipeline's `health_check` re-asserts step 5. It is **host-only** on
purpose: the public hostname still points at the previous origin until the
ingress cutover (flip `posthog.stevens.fyi` in `~/.cloudflared/config.yml` →
`http://localhost:18080`, restart the tunnel's unit, verify every hostname on
that tunnel).

## Host facts

- Target: stevenspc (local to the runner), `$BOX_DIR=/home/stevens/apps/posthog`.
  The cachyos box was the target 2026-09-20 → 2026-09-21; its `/srv/apps/posthog`
  and volumes were retired after the move (backup tars may still exist there).
- Data volumes (`clickhouse-data`, `postgres-data`, `objectstorage-data`,
  `seaweedfs`, `zookeeper-data/datalog`): named `posthog_*` under
  `/var/lib/docker/volumes` on the target. They are the only non-rebuildable
  state — back them up off-host before destructive work.
- RAM: trimmed stack idles at roughly 3–4 GB; the pre-trim stack peaked past
  12 GB during boots (which is why it left the small box).

## Operations

- **Rollback** of a bad deploy: `git revert` + push (the pipeline redeploys),
  or on the target `cd $BOX_DIR && docker compose -f docker-compose.yml -f
  docker-compose.trim.yml up -d` after checking out the previous SHA.
- **Cutover/rollback of ingress**: `~/.cloudflared/config.yml` (locally managed
  tunnel) — backup, edit `posthog.stevens.fyi`'s service URL, restart the
  supervising unit, re-verify every hostname on that tunnel.
- **Updating PostHog**: the app image is pinned by digest (`POSTHOG_APP_IMAGE`
  in the vault `.env`) so routine deploys never recreate web/worker on a
  surprise upstream `latest`. To upgrade: pick the new digest from
  [Docker Hub](https://hub.docker.com/r/posthog/posthog/tags) (or
  `docker pull posthog/posthog:latest && docker inspect -f '{{index .RepoDigests 0}}'`
  on any docker host), update the vault, push a no-op commit, watch Forge —
  expect one long (15–25 min) recreate-and-migrate boot.
- **Data migration between hosts**: stop the stack (cold volumes), `tar` each
  volume via a data-only container, ship, extract into the target's volumes
  (wipe first — the tars are the backup), bring up. ClickHouse replicated
  tables additionally need the `zookeeper-data` + `zookeeper-datalog` volumes
  from the same snapshot, or every `ReplicatedMergeTree` goes readonly.
