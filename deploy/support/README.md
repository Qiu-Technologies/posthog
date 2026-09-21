# support/ — bind-mounted dirs the hobby compose expects at the project root

Upstream's `bin/deploy-hobby` generates these at the deploy root; they are not
committed upstream, so this fork carries copies to keep the box deploy fully
git-driven. `deploy-box.sh` materializes them at `$BOX_DIR` on the box:

- `compose/start`, `compose/wait`, `compose/temporal-django-worker` — the web /
  worker entry wrappers (wait for ClickHouse+Postgres, run migrations, serve).
- `docker/postgres-init-scripts/` — **empty here on purpose**: the compose
  bind-mounts `./docker/postgres-init-scripts`, which the box symlinks into the
  sparse clone (`posthog/docker/postgres-init-scripts`), where the real init
  scripts live.
- `products/` — same story: empty here; the box symlinks it to the clone's
  `products/` (the compose bind-mounts it read-only).
