# BreakTest Self-Hosted Runtime

This repository contains the public deployment bundle for running BreakTest from prepared Docker images. It does not contain application source code.

> **Note:** This repository is a generated release artifact. Its content is
> maintained in the BreakTest source repository (`deploy/selfhost/`) and
> published here by the release pipeline, one commit per release. Direct
> commits or pull requests against this repository will be overwritten by the
> next release — please report issues to BreakTest support instead.

## Requirements

- Docker Engine
- Docker Compose v2, or `docker-compose`
- `openssl`
- Network access to `https://breaktest.io` for pairing and startup validation

## Install

Run the guided installer:

```bash
./install.sh
```

The installer asks for:

- HTTP port
- TLS mode: `disabled`, `letsencrypt`, or `external`. `letsencrypt` asks for
  the HTTPS port and email address; `external` is for an upstream proxy that
  terminates HTTPS and forwards HTTP to this stack
- The public URL users and remote load generators use to reach BreakTest, with
  detected local IP addresses offered as choices
- Service timezone, prefilled from the host machine when detectable

A local load generator is always included. It is labeled `Local` and allowed to
run synthetic monitoring. Container mode is preferred because each JMeter or K6
test runs in its own workload container. When a load-generator image is already
local, the installer probes whether a Docker socket can be bind-mounted and
selects `process` mode if the probe fails. On a first install, `./start.sh`
performs that probe immediately after pulling the image and falls back to
process mode if needed.

It writes `config.env` and generates local MongoDB, PostgreSQL, JWT, and credential-encryption secrets.
Image namespace, Compose project name, single-customer generator scope,
Docker-managed TimescaleDB storage, and disabled AI are safe installer defaults.
They remain editable in `config.env` after installation.
The configured timezone controls service logs, PostgreSQL defaults, and the
daily retention cleanup schedule (03:00 in that timezone). Dates in the web
interface are rendered in each viewer's browser timezone.

Full backups are written to `BACKUP_PATH`. Each archive includes `config.env`
alongside MongoDB, PostgreSQL, and Grafana data so restore has the matching
secrets. Fresh generated configurations keep the two newest timestamped
archives with `LOCAL_BACKUP_RETENTION_COUNT=2`; an older `config.env` without
that key keeps all existing archives on its first run. For Hetzner Storage Box,
`BACKUP_INSTALLATION_NAME` is optional for backward compatibility: leaving it
empty preserves the old remote directory, while setting a unique name stores
new backups below that name.
Run a backup from the bundle directory with `./full_backup.sh`. Manual backups
should run in a durable shell or service session: interrupting the command
aborts the backup and terminates only the database dump sessions owned by that
run. `MAX_PARALLEL` controls concurrent PostgreSQL dumps, while
`BACKUP_DISK_HEADROOM_GB` adds free-space headroom to the preflight check.

## Public URL and TLS

The externally visible origin and local TLS behavior are configured separately:

```env
BREAKTEST_PUBLIC_URL=https://office.example.com
BREAKTEST_TLS_MODE=letsencrypt
```

`BREAKTEST_PUBLIC_URL` is the canonical origin for application links, secure
cookies, and external load-generator connections. BreakTest automatically maps
`https` to `wss` and `http` to `ws`.

`BREAKTEST_TLS_MODE` accepts:

- `disabled`: Traefik serves HTTP on `HTTP_PORT`; the public URL must use `http`.
- `letsencrypt`: Traefik serves HTTPS and obtains a certificate; the public URL
  must use `https`, and ports `HTTP_PORT` and `HTTPS_PORT` must be reachable.
- `external`: an upstream proxy terminates HTTPS and forwards HTTP to
  `HTTP_PORT`; the public URL must use `https`, and this stack does not publish
  port 443.

Upgrades automatically migrate legacy `CONTROLLER_HOST`, `ENABLE_SSL`, and
`ENABLE_HTTPS` settings to the canonical variables and retain a timestamped
backup of `config.env`. Legacy Traefik values matching the generated defaults
are removed; customized `TRAEFIK_*` values are preserved and reported during
startup. Contradictory legacy SSL flags fail with a clear error instead of
silently selecting an insecure connection.

Then start:

```bash
./start.sh
```

## Images and Versions

The compose file pulls BreakTest runtime images from Docker Hub:

```text
breakingit/breaktest-backend:${BREAKTEST_BACKEND_VERSION}
breakingit/breaktest-frontend:${BREAKTEST_FRONTEND_VERSION}
breakingit/breaktest-ai-assistant:${BREAKTEST_AI_ASSISTANT_VERSION}
breakingit/breaktest-loadgenerator:${BREAKTEST_LOADGENERATOR_VERSION}
breakingit/breaktest-pg-proxy:${BREAKTEST_PG_PROXY_VERSION}
```

The bundle release version is pinned in `BREAKTEST_VERSION`. Each image also
has its own version in `version.env`, because unchanged images are reused from
the previous release instead of being rebuilt and republished. The release
pipeline writes these values; do not edit `version.env` by hand.

To temporarily run a different version (rollback, release candidate), set
`BREAKTEST_VERSION` in `config.env`; it takes precedence over all per-image
versions in `version.env`. Remove the override to follow bundle releases again.

### Modified k6 component (AGPL-3.0)

The optional BreakTest load generator includes a modified version of
[Grafana k6](https://github.com/grafana/k6). The complete corresponding source code for
Breaking-IT's modified k6 component, including the build scripts and the GNU Affero General
Public License v3.0 text, is publicly available at
[Breaking-IT/k6](https://github.com/Breaking-IT/k6).

The fork's [`breakingit` branch](https://github.com/Breaking-IT/k6/tree/breakingit) contains
the current source and immutable source-release tags are published there. This notice applies
to the k6 component only; it does not change the license terms for other BreakTest components.

## Local Load Generator

The guided installer always starts a local load generator. Disable it later by
clearing `COMPOSE_PROFILES`:

```env
COMPOSE_PROFILES=loadgenerator
```

Leave `COMPOSE_PROFILES` empty if this controller should run without a local generator.

The local load generator can be scoped in `config.env`:

```env
LOAD_GENERATOR_RUN_MODE=container
# LOAD_GENERATOR_DOCKER_SOCKET=/var/run/docker.sock
# LOAD_GENERATOR_CPU_LIMIT=4.0
# LOAD_GENERATOR_MEMORY_LIMIT=4096m
LOAD_GENERATOR_PUBLIC=false
LOAD_GENERATOR_CUSTOMER_NAME=Default
```

`container` is preferred because every JMeter or K6 test runs in its own
workload container. When the image is available, the installer probes whether
a Docker socket can actually be bind-mounted (preferring
`/var/run/docker.sock` inside Docker Desktop or Colima VMs over the macOS
client path from `DOCKER_HOST` / `docker context inspect`). On a first install,
`./start.sh` performs the real probe after pulling the image. It also repeats
the check on later starts and falls back to process mode if the socket is no
longer mountable.
Set `LOAD_GENERATOR_DOCKER_SOCKET` only when the probe must use a specific
path. The optional CPU and memory limits cap the load generator; container-mode
test workloads inherit the same limits.

The guided installer always keeps the local generator private to the default
customer. Service-provider deployments can change these advanced settings in
`config.env` after installation.

## Grafana

Grafana is disabled by the guided installer. To enable it later, set:

```env
GRAFANA_ENABLED=true
GRAFANA_ADMIN_PASSWORD=choose-a-strong-password
GRAFANA_IP_ALLOWLIST=127.0.0.1/32,::1/128,203.0.113.10/32
```

`./start.sh` adds the `grafana` Compose profile, serves Grafana at
`/grafana` on the public URL, provisions the BreakTest System Monitoring
dashboard and a Timescale datasource for `breaktest_monitoring`, and generates
credentials for the dedicated `graf_breaktest_monitoring_ro` database role.
Sign in as `admin` with `GRAFANA_ADMIN_PASSWORD`.
Traefik only accepts Grafana traffic from `GRAFANA_IP_ALLOWLIST`
(localhost only by default). Bare IPs are expanded to `/32` or `/128`.
Grafana state is stored in the `grafana_data` Docker volume.

When `BREAKTEST_TLS_MODE=external`, also configure the IP or network of the
upstream reverse proxy:

```env
TRAEFIK_TRUSTED_PROXY_IPS=10.0.0.10/32
```

The proxy must send `X-Forwarded-For` with the real client address. BreakTest
trusts that header only when the request comes from `TRAEFIK_TRUSTED_PROXY_IPS`;
the Grafana allowlist then checks the forwarded client address. Never set this
to an unrestricted range such as `0.0.0.0/0`.

## AI Assistant

The AI assistant is disabled by the guided installer. To enable it later, add
`ai-assistant` to `COMPOSE_PROFILES`, set `AI_ASSISTANT_ENABLED=true`, and
configure either `ANTHROPIC_API_KEY` or both `OPENAI_ACCESS_TOKEN` and
`OPENAI_REFRESH_TOKEN` in `config.env`.

Backend access also requires a BreakTest license with the AI assistant entitlement enabled.

## Operations

Start:

```bash
./start.sh
```

Follow logs:

```bash
./start.sh -f
```

Start with locally built images instead of pulling from Docker Hub:

```bash
./start.sh --no-pull -f
```

`start.sh` checks for free disk space before Docker pulls or starts the stack,
waits for the database and backend health checks, and exits with service logs if
they do not become healthy. The default safety threshold is 2 GiB and can be
changed with `BREAKTEST_MIN_FREE_DISK_GB`. The startup health-check budget can
be increased for large installations with
`BREAKTEST_STARTUP_HEALTH_TIMEOUT_SECONDS` (default: 300 seconds). A
`./start.sh --restart <service>` operation skips the full-stack health wait.

Set a static Docker Compose project name in `config.env` to isolate containers and volumes:

```env
BREAKTEST_COMPOSE_PROJECT_NAME=breaktest-selfhost-test
```

Removing the self-host directory does not remove Docker named volumes. For a
deliberate, destructive fresh reset, stop the stack and remove its project
volumes explicitly (after taking any needed backups):

```bash
./stop.sh
docker compose --env-file version.env --env-file config.env \
  -f docker-compose.yaml -p "${BREAKTEST_COMPOSE_PROJECT_NAME:-breaktest}" down -v
```

TimescaleDB uses the project-scoped Docker volume by default. To store its
database on a dedicated host disk, configure an absolute path in `config.env`:

```env
POSTGRES_DATA_PATH=/data/timescaledb
```

Both `start.sh` and `upgrade.sh` preserve this setting and validate/create the
directory before starting TimescaleDB. Stop the stack before changing this
setting on an existing installation; changing it selects a different
PostgreSQL data directory and does not copy data automatically.

Then start an isolated local test stack with its own Docker volumes:

```bash
./start.sh --no-pull -f
```

Stop that isolated test stack. Docker volumes are preserved:

```bash
./stop.sh
```

Restart one service:

```bash
./start.sh -r backend
```

Upgrade to the latest release (updates the bundle via `git pull`, then pulls
the images pinned by the new `version.env`, restarts services, and removes the
superseded images after the replacement stack starts successfully):

```bash
./upgrade.sh
```

Pull and restart at the currently pinned version without updating the bundle:

```bash
./upgrade.sh --no-bundle-update
```

Stop:

```bash
./stop.sh
```

## Production Notes

- In `letsencrypt` mode, DNS for the public URL hostname must point at the server and ports 80/443 must be reachable for Let's Encrypt HTTP-01 validation.
- Do not mount application source code into runtime containers.
- Keep `config.env` private.
- Back up Docker volumes and the `backups/` directory before upgrades.
- Support should be tied to official BreakTest images and a valid license.
# Licensing

Start BreakTest, sign in as the interactive SuperAdmin, and open **Platform → License**. Pair the installation with your breaktest.io account, approve its short code in `/portal`, create or select a license there, then refresh and activate it in BreakTest. Portal credentials and raw license keys are never stored in Selfhost.

Official Selfhost images contact `https://breaktest.io` at every backend start. If that check fails because of a connection problem or HTTP 5xx response, BreakTest may continue using its last signed license until 72 hours after the last successful license validation, including across restarts. A definitive license-server rejection (for example, an expired, revoked, or unavailable license) clears that grace immediately. The License page remains available while restricted or operating in grace.
