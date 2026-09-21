#!/usr/bin/env bash
# deploy-box.sh — deploy the PostHog hobby stack to a target host.
#
# This fork exists to own the self-hosted PostHog deployment: upstream images
# (pulled on the target per REGISTRY_URL/POSTHOG_APP_IMAGE), our compose config
# under deploy/, and target state under BOX_DIR. The CI box never builds
# PostHog — it ships config + secrets and drives `docker compose` on the target.
#
# Target selection (runner-side, NOT in this public repo):
#   ${POSTHOG_DEPLOY_CONF:-~/.config/posthog-deploy/env} is sourced if present
#   and may set BOX_SSH (default: cachy-ssh wrapper; "local" = run on this
#   host), BOX_DIR, PROXY_BIND_IP, HEALTH_URL. Explicit env vars win over the
#   conf file.
#
# Layout on the target ($BOX_DIR):
#   .env / .env.services     secrets — from the vault, 0600, NEVER in git
#   posthog/                 sparse clone of this fork, pinned to the deploy SHA
#   compose/                 hobby support scripts (copied from deploy/support)
#   products -> posthog/products, docker/postgres-init-scripts -> posthog/...  (symlinks)
#   share/                   GeoLite2 db (data, MaxMind license — not in git)
#
# usage: deploy-box.sh          (driven by the Forge pipeline; overrides via env)
set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root (the fork checkout)

DEPLOY_CONF="${POSTHOG_DEPLOY_CONF:-$HOME/.config/posthog-deploy/env}"
if [ -f "$DEPLOY_CONF" ]; then
  # shellcheck disable=SC1090
  . "$DEPLOY_CONF"
  echo "→ target conf: $DEPLOY_CONF"
fi

SHA="$(git rev-parse HEAD)"
SHORT="${SHA:0:7}"
BOX_SSH="${POSTHOG_BOX_SSH:-${BOX_SSH:-$HOME/.local/bin/cachy-ssh}}"
BOX_DIR="${POSTHOG_BOX_DIR:-${BOX_DIR:-/srv/apps/posthog}}"
FORK_URL="${POSTHOG_FORK_URL:-https://github.com/Qiu-Technologies/posthog.git}"
VAULT_ENV="${POSTHOG_VAULT_ENV:-posthog/deploy-env}"
VAULT_SERVICES="${POSTHOG_VAULT_SERVICES:-posthog/env-services}"
SHARE_SRC="${POSTHOG_SHARE_SRC:-$HOME/opt/posthog/share}"
PROXY_BIND_IP="${POSTHOG_PROXY_BIND_IP:-${PROXY_BIND_IP:-10.0.0.201}}"
PROXY_PORT="${POSTHOG_PROXY_PORT:-${PROXY_PORT:-18080}}"
HEALTH_URL="${POSTHOG_HEALTH_URL:-${HEALTH_URL:-http://$PROXY_BIND_IP:$PROXY_PORT/}}"

if [ "$BOX_SSH" = "local" ]; then
  R() { bash -c "$1"; }
  echo "→ target: LOCAL ($BOX_DIR)"
else
  R() { "$BOX_SSH" "$1"; }
  echo "→ target: $BOX_DIR via $BOX_SSH"
fi
# The compose project lives at $BOX_DIR root (exactly like the tier-0 hobby
# layout): env_file ./.env.services and the implicit .env both resolve there,
# and the ./posthog ./compose ./share ./products ./docker paths are its
# siblings. The files in git live under deploy/ in the clone and are copied up.
# The trim overlay is merged last (see docker-compose.trim.yml).
COMPOSE="docker compose -f $BOX_DIR/docker-compose.yml -f $BOX_DIR/docker-compose.trim.yml"

echo "→ posthog box deploy @ $SHORT"

exec 9>/tmp/posthog-box-deploy.lock
flock 9   # host deploys never interleave

echo "→ [1/5] env files from the vault → $BOX_DIR (.env, .env.services, 0600)"
R "mkdir -p '$BOX_DIR' && chmod 700 '$BOX_DIR'"
pass show "$VAULT_ENV"      | R "cat > '$BOX_DIR/.env' && chmod 600 '$BOX_DIR/.env'"
pass show "$VAULT_SERVICES" | R "cat > '$BOX_DIR/.env.services' && chmod 600 '$BOX_DIR/.env.services'"

echo "→ [2/5] deploy tree from git on the box @ $SHORT"
R "if [ ! -d '$BOX_DIR/posthog/.git' ]; then git clone --filter=blob:none --sparse '$FORK_URL' '$BOX_DIR/posthog'; fi"
R "cd '$BOX_DIR/posthog' && git fetch --depth 50 origin '$SHA' && git checkout -q '$SHA' && git sparse-checkout set deploy products docker posthog/idl posthog/user_scripts"
# Compose project files at $BOX_DIR root (the known-good hobby layout).
R "cp -f '$BOX_DIR/posthog/deploy/docker-compose.yml' '$BOX_DIR/posthog/deploy/docker-compose.base.yml' '$BOX_DIR/posthog/deploy/docker-compose.override.yml' '$BOX_DIR/posthog/deploy/docker-compose.trim.yml' '$BOX_DIR/'"

# Support dirs the compose bind-mounts from the project dir (deploy root):
#   ./compose ./products ./docker/postgres-init-scripts ./share
R "cd '$BOX_DIR' && mkdir -p compose && cp -f posthog/deploy/support/compose/* compose/ && chmod +x compose/start compose/wait compose/temporal-django-worker"
R "cd '$BOX_DIR' && ln -sfn posthog/products products && mkdir -p docker && ln -sfn '$BOX_DIR/posthog/docker/postgres-init-scripts' docker/postgres-init-scripts"

# GeoLite2 db — data under MaxMind license, deliberately not in git. Ship from
# the CI box's previous deploy if present; otherwise leave a warning (geoip off).
if [ -f "$SHARE_SRC/GeoLite2-City.mmdb" ]; then
  echo "→ shipping GeoLite db (share/)"
  tar -C "$SHARE_SRC" -czf - . | R "mkdir -p '$BOX_DIR/share' && tar -xzf - -C '$BOX_DIR/share'"
else
  echo "⚠ $SHARE_SRC/GeoLite2-City.mmdb not found on the CI box — geoip will be off"
fi

echo "→ [3/5] compose pull + up on the box (background — the images are GBs)"
R "cd '$BOX_DIR' && rm -f deploy-run.log && PROXY_BIND_IP='$PROXY_BIND_IP' nohup bash -c '
  echo \"[\$(date -Is)] pull start sha=$SHORT\" >> deploy-run.log
  # A failed pull (e.g. Docker Hub anonymous rate limit) must not block the
  # deploy: compose then runs the cached images, and the health check below
  # is the real gate. Re-run the pipeline later to pick up new images.
  docker compose -f docker-compose.yml -f docker-compose.trim.yml pull >> deploy-run.log 2>&1 \\
    || echo \"[\$(date -Is)] pull FAILED — continuing with cached images\" >> deploy-run.log
  echo \"[\$(date -Is)] up start\" >> deploy-run.log
  docker compose -f docker-compose.yml -f docker-compose.trim.yml up -d >> deploy-run.log 2>&1
  echo \"[\$(date -Is)] DONE\" >> deploy-run.log
' >/dev/null 2>&1 & echo bg-started"

echo "→ [4/5] waiting for pull + up (bounded ~15 min)"
DONE=0
for i in $(seq 1 100); do
  sleep 15
  if R "grep -q '^\[.*\] DONE' '$BOX_DIR/deploy-run.log' 2>/dev/null"; then DONE=1; echo "  finished after ~$((i * 15))s"; break; fi
done
if [ "$DONE" != 1 ]; then
  echo "✗ timed out — tail of $BOX_DIR/deploy-run.log on the box:"
  R "tail -25 '$BOX_DIR/deploy-run.log'" || true
  exit 1
fi

echo "→ [5/5] health: polling $HEALTH_URL (the path the tunnel uses)"
# 100 x 15s = 25 min. Steady-state redeploys (no image change) answer in ~1 min;
# a recreate on a new app image re-runs Django + ClickHouse + async migrations.
# PostHog answers / with a 302 to /login — that IS the healthy signal.
for i in $(seq 1 100); do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$HEALTH_URL" 2>/dev/null || echo 000)"
  case "$CODE" in
    200|302) echo "✓ posthog web serving (deploy $SHORT, http $CODE)"; exit 0 ;;
  esac
  [ "$i" = 100 ] && break
  sleep 15
done
echo "✗ posthog web did not come up (last http: $CODE). Container state:"
R "cd '$BOX_DIR' && docker compose -f docker-compose.yml -f docker-compose.trim.yml ps --format '{{.Name}} {{.Status}}' | head -30"
R "cd '$BOX_DIR' && docker compose -f docker-compose.yml -f docker-compose.trim.yml logs --tail 15 web" || true
exit 1