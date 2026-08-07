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

- TLS mode (`disabled`, `letsencrypt`, or `external`)
- The public URL users and remote load generators use to reach BreakTest
- HTTP port, and the HTTPS port only when HTTPS is enabled
- Service timezone, prefilled from the host machine when detectable
- Whether to start a local load generator
- Local load generator location label
- Whether that generator may run synthetic monitoring

It writes `config.env` and generates local MongoDB, PostgreSQL, JWT, and credential-encryption secrets.
Image namespace, Compose project name, single-customer generator scope,
Docker-managed TimescaleDB storage, and disabled AI are safe installer defaults.
They remain editable in `config.env` after installation.
The configured timezone controls service logs, PostgreSQL defaults, and the
daily retention cleanup schedule (03:00 in that timezone). Dates in the web
interface are rendered in each viewer's browser timezone.

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
breakingit/breaktest-backend:${BREAKTEST_VERSION}
breakingit/breaktest-frontend:${BREAKTEST_VERSION}
breakingit/breaktest-ai-assistant:${BREAKTEST_VERSION}
breakingit/breaktest-loadgenerator:${BREAKTEST_VERSION}
breakingit/breaktest-pg-proxy:${BREAKTEST_VERSION}
```

All images of a release share one version. The version is pinned in
`version.env`, which ships with this bundle and is written by the release
pipeline — each bundle release always points at the image version it was
released with. Do not edit `version.env` by hand.

To temporarily run a different version (rollback, release candidate), set
`BREAKTEST_VERSION` in `config.env`; it takes precedence over `version.env`.
Remove the override to follow bundle releases again.

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

The local load generator is optional. The installer controls it with:

```env
COMPOSE_PROFILES=loadgenerator
```

Leave `COMPOSE_PROFILES` empty if this controller should run without a local generator.

The local load generator can be scoped in `config.env`:

```env
LOAD_GENERATOR_RUN_MODE=container
# LOAD_GENERATOR_CPU_LIMIT=4.0
# LOAD_GENERATOR_MEMORY_LIMIT=4096m
LOAD_GENERATOR_PUBLIC=false
LOAD_GENERATOR_CUSTOMER_NAME=Default
```

`container` is the preferred run mode because every JMeter or K6 test runs in
its own workload container. Set `LOAD_GENERATOR_RUN_MODE=process` only when
Docker socket access is unavailable or direct in-agent execution is required.
The optional CPU and memory limits cap the load generator; container-mode test
workloads inherit the same limits. The startup scripts discover the local
Docker socket from `DOCKER_HOST` or the active Docker context; set
`LOAD_GENERATOR_DOCKER_SOCKET` only when it must be overridden explicitly.

The guided installer always keeps the local generator private to the default
customer. Service-provider deployments can change these advanced settings in
`config.env` after installation.

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

Set a static Docker Compose project name in `config.env` to isolate containers and volumes:

```env
BREAKTEST_COMPOSE_PROJECT_NAME=breaktest-selfhost-test
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

## Not Included

The public self-host bundle does not deploy Grafana.

## Production Notes

- In `letsencrypt` mode, DNS for the public URL hostname must point at the server and ports 80/443 must be reachable for Let's Encrypt HTTP-01 validation.
- Do not mount application source code into runtime containers.
- Keep `config.env` private.
- Back up Docker volumes and the `backups/` directory before upgrades.
- Support should be tied to official BreakTest images and a valid license.
# Licensing

Start BreakTest, sign in as the interactive SuperAdmin, and open **Platform → License**. Pair the installation with your breaktest.io account, approve its short code in `/portal`, create or select a license there, then refresh and activate it in BreakTest. Portal credentials and raw license keys are never stored in Selfhost.

Official Selfhost images contact `https://breaktest.io` at every backend start. If that check fails because of a connection problem or HTTP 5xx response, BreakTest may continue using its last signed license until 72 hours after the last successful license validation, including across restarts. A definitive license-server rejection (for example, an expired, revoked, or unavailable license) clears that grace immediately. The License page remains available while restricted or operating in grace.
