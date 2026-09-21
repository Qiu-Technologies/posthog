# PostHog self-hosted deployment (hobby) — owned by this fork

This fork of `PostHog/posthog` exists to put the self-hosted PostHog stack under
git control and deploy it to the **cachyos box** through Forge. Upstream
application code is used as-is (images pulled from the registries); everything
deployment-specific lives in `deploy/`.

> The fork is **public** — GitHub does not allow private forks of public repos.
> Everything under `deploy/` is config only: the real secrets live in the
> vault (`pass posthog/deploy-env`, `pass posthog/env-services`) and on the box
> at `/srv/apps/posthog/.env*` (0600). Never commit real `.env` files.

**Default branch is `main` while upstream uses `master`** — deliberate: the
Forge controller only runs pipelines for the default branch (`main`), and
deploys should be deliberate anyway. To take an upstream upgrade: fetch
`https://github.com/PostHog/posthog.git`, merge `master` into `main`, resolve,
push — Forge redeploys.

## Layout

```
deploy/
  docker-compose.yml        the hobby stack (upstream hobby file as deployed,
                            with the proxy bind parameterized: PROXY_BIND_IP)
  docker-compose.base.yml   upstream base services (extends targets)
  docker-compose.override.yml our override (TLS off behind cloudflared)
  .env.example              every key the deploy needs — VALUES ARE PLACEHOLDERS
  scripts/deploy-box.sh     the Forge production step (see below)
  support/                  bind-mounted support dirs that upstream generates
    compose/                start / wait / temporal-django-worker
    docker/postgres-init-scripts/  (empty — the real ones come from the clone)
    products/               (empty dir — the real ones come from the clone)
pipeline.yml                Forge pipeline (root; the controller reads this)
```

## How a deploy works

Push to `main` → Forge webhook → `build` validates the compose files →
`production` runs `deploy/scripts/deploy-box.sh` on the CI runner (host step):

1. Ships `.env` / `.env.services` from the vault to the box (`/srv/apps/posthog/`, 0600).
2. Sparse-clones **this fork** on the box and checks out the pushed SHA
   (`--filter=blob:none`, only `deploy/ products/ docker/ posthog/idl
   posthog/user_scripts` are materialized) — the box always runs the config
   that is in git at the deployed commit. The compose project files are then
   copied from `deploy/` to `/srv/apps/posthog/` root, matching the tier-0
   hobby layout (`./posthog`, `./compose`, `./share`, `./products`,
   `./docker`, `.env`, `.env.services` are all siblings of the compose file).
3. Materializes the support dirs (`compose/`, `products` and
   `docker/postgres-init-scripts` symlinks into the clone; `share/` GeoLite db
   shipped from the CI box — MaxMind license keeps it out of git).
4. Runs `docker compose pull && up -d` **on the box in the background** (the
   images are GBs; the step polls `deploy-run.log`, bounded at ~15 min), with
   `PROXY_BIND_IP=10.0.0.201` so the tier-0 cloudflared tunnel can reach the
   proxy from another box.
5. Health: polls `http://10.0.0.201:18080/` until the web app answers 200.

The pipeline's `health_check` re-asserts step 5. It is **box-only** on purpose:
the public hostname still points at the previous origin until the ingress
cutover (flip `posthog.stevens.fyi` in `~/.cloudflared/config.yml` →
`http://10.0.0.201:18080`, restart the tunnel's unit, verify).

## Box facts

- Target: cachyos (`/srv/apps/posthog`), transport `~/.local/bin/cachy-ssh`
  (wired → tailnet SOCKS → wifi).
- Data volumes (`clickhouse-data`, `postgres-data`, `objectstorage-data`,
  `seaweedfs`): live on the box under the compose project. They are the only
  non-rebuildable state — back them up off-box before destructive work.
- RAM: the stack idles at roughly 5–6 GB (ClickHouse ~0.9 GB, worker ~1 GB,
  six ingestion consumers ~0.25 GB each). The box has 12 GB — PostHog is the
  heavyweight on it.

## Operations

- **Rollback** of a bad deploy: `git revert` + push (the pipeline redeploys),
  or on the box `cd /srv/apps/posthog && docker compose -f
  posthog/deploy/docker-compose.yml up -d` after checking out the previous SHA.
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
- **Data migration from the old tier-0 deploy**: see the migration notes in the
  homelab infra records; volumes were shipped cold (stack stopped) with
  `tar` via data-only containers.
