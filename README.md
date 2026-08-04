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

- Hostname
- Whether to enable HTTPS with Let's Encrypt
- HTTP/HTTPS ports
- Whether to start a local load generator
- Local load generator location label
- Whether to configure the AI assistant provider

It writes `config.env` and generates local MongoDB, PostgreSQL, JWT, and credential-encryption secrets.

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

## Local Load Generator

The local load generator is optional. The installer controls it with:

```env
COMPOSE_PROFILES=loadgenerator
```

Leave `COMPOSE_PROFILES` empty if this controller should run without a local generator.

The local load generator can be scoped in `config.env`:

```env
LOAD_GENERATOR_PUBLIC=true
LOAD_GENERATOR_CUSTOMER_NAME=Default
```

## AI Assistant

The AI assistant is optional and starts only when the `ai-assistant` profile is enabled. The installer adds that profile when you configure either `ANTHROPIC_API_KEY` or both `OPENAI_ACCESS_TOKEN` and `OPENAI_REFRESH_TOKEN`.

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
the images pinned by the new `version.env` and restarts services):

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

- If HTTPS is enabled, DNS for the configured hostname must point at the server and ports 80/443 must be reachable for Let's Encrypt HTTP-01 validation.
- Do not mount application source code into runtime containers.
- Keep `config.env` private.
- Back up Docker volumes and the `backups/` directory before upgrades.
- Support should be tied to official BreakTest images and a valid license.
# Licensing

Start BreakTest, sign in as the interactive SuperAdmin, and open **Platform → License**. Pair the installation with your breaktest.io account, approve its short code in `/portal`, create or select a license there, then refresh and activate it in BreakTest. Portal credentials and raw license keys are never stored in Selfhost.

Official Selfhost images contact `https://breaktest.io` at every backend start. If that validation is unavailable, the backend starts restricted and leaves the License page available. A running process that already validated may use its signed runtime lease for at most 72 hours. Restart always requires a fresh online check.
