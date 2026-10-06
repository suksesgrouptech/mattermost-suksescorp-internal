# Custom Mattermost 10.12.4 source build

This repository is pinned for the Mattermost 10.12.4 source revision:

```text
463e0d0d3930782d3c975da26c991dcbfccd751c
```

`Dockerfile.custom` uses the source tree's official Makefile/release targets to build the webapp, Linux amd64 server, and Team Edition package. It then places that package into a runtime image based on `server/build/Dockerfile`: Ubuntu Noble build stage, Mattermost uid/gid 2000, distroless Debian 12 runtime, the same executable paths and healthcheck. The local test script verifies the checked-out commit and tracked `server/` and `webapp/` source before invoking Docker. `.dockerignore` omits `.git` to keep the Docker context small; the verified full SHA is passed into the Makefile linker metadata and image labels.

The Mattermost API ping endpoint reports health, not the application version. The disposable test therefore checks both `GET /api/v4/system/ping` and the binary's `mattermost version` output, including its embedded full build hash.

## Build and run the disposable smoke test

Requirements: Docker with the Docker Compose plugin and BuildKit enabled. The build downloads Go/npm modules and Mattermost's prepackaged, signed plugins, so it needs network access.

From the repository root in PowerShell:

```powershell
./scripts/test-local.ps1
```

The script builds the image and starts a disposable PostgreSQL container plus Mattermost on `127.0.0.1:18065`. It uses the Compose project `mattermost-10-12-4-test` and only that project's temporary volumes. It refuses to start if containers, volumes, or networks for that project already exist. After checks, it runs `docker compose down --volumes --remove-orphans` for that project. The built image remains locally tagged `mattermost-custom:10.12.4-audit`.

The script checks:

1. `/api/v4/system/ping` returns `status: OK`.
2. `mattermost version` reports `10.12.4` and build hash `463e0d0d3930782d3c975da26c991dcbfccd751c`.
3. Optionally, `POST /api/v4/posts` returns HTTP 201 when both `MM_TEST_BEARER_TOKEN` and `MM_TEST_CHANNEL_ID` are set. Use a token and channel created only in the disposable local instance. The script never prints the token.

For the optional post check, create a local test account/channel in the disposable instance, create a personal access token for that account, and set the variables in the current PowerShell session before running the script. Do not use production values.

Equivalent guarded direct image build command (without starting containers):

```powershell
if ((git rev-parse HEAD) -ne '463e0d0d3930782d3c975da26c991dcbfccd751c') {
  throw 'Checkout is not the pinned Mattermost revision.'
}
git diff --quiet 463e0d0d3930782d3c975da26c991dcbfccd751c -- server webapp
if ($LASTEXITCODE -ne 0) { throw 'Mattermost source files have local tracked changes.' }

docker build --platform linux/amd64 `
  --build-arg MATTERMOST_VERSION=10.12.4 `
  --build-arg SOURCE_REVISION=463e0d0d3930782d3c975da26c991dcbfccd751c `
  -t mattermost-custom:10.12.4-audit `
  -f Dockerfile.custom .
```

The official package target cleans and recreates `server/dist`; it runs inside the temporary build stage, not in the working tree.

## Future deployment template

`deploy/docker-compose.yml` is a template only; it has not been deployed. It expects `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, and `MM_SERVICESETTINGS_SITEURL` to be supplied by the future deployment environment. Do not commit a populated `.env` file. If a database password contains URL-reserved characters, percent-encode it in the `MM_SQLSETTINGS_DATASOURCE` URL.

The template declares production volumes as external so Compose will not create empty, similarly named volumes. These exact names came from the read-only production audit:

| Production volume | Container path |
|---|---|
| `devops-playground-chatmattermostsukses-sewtr3_postgres_data` | `/var/lib/postgresql/data` |
| `devops-playground-chatmattermostsukses-sewtr3_mattermost_config` | `/mattermost/config` |
| `devops-playground-chatmattermostsukses-sewtr3_mattermost_data` | `/mattermost/data` |
| `devops-playground-chatmattermostsukses-sewtr3_mattermost_logs` | `/mattermost/logs` |
| `devops-playground-chatmattermostsukses-sewtr3_mattermost_plugins` | `/mattermost/plugins` |
| `devops-playground-chatmattermostsukses-sewtr3_mattermost_client_plugins` | `/mattermost/client/plugins` |
| `devops-playground-chatmattermostsukses-sewtr3_mattermost_bleve` | `/mattermost/bleve-indexes` |

The local test Compose file does not reference these external names, the production network, or production credentials. Keep the deployment template unused until the migration is separately reviewed and authorized.
