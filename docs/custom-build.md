# Custom Mattermost 10.12.4 source build

The source of truth is the `company-baseline-10.12.4` tag, which must resolve to this Mattermost 10.12.4 source revision:

```text
463e0d0d3930782d3c975da26c991dcbfccd751c
```

`Dockerfile.custom` uses the source tree's official Makefile/release targets to build the webapp, Linux amd64 server, and Team Edition package. It then places that package into a runtime image based on `server/build/Dockerfile`: Ubuntu Noble build stage, Mattermost uid/gid 2000, distroless Debian 12 runtime, the same executable paths and healthcheck. The local test script verifies the baseline tag, identical `server/` and `webapp/` Git trees, clean build inputs, and root release metadata before invoking Docker. It supports this repository's later scaffolding commits while rejecting changes to the pinned Mattermost source. `.dockerignore` omits `.git` to keep the Docker context small; the verified full SHA is passed into the Makefile linker metadata and image labels. Build stages are pinned to amd64 and base image digests; apt package repositories remain time-dependent.

The Mattermost API ping endpoint reports health, not the application version. The disposable test therefore checks both `GET /api/v4/system/ping` and the binary's `mattermost version` output, including its embedded full build hash.

## Build and run the disposable smoke test

Requirements: Docker with the Docker Compose plugin and BuildKit enabled. The build downloads Go/npm modules and Mattermost's prepackaged, signed plugins, so it needs network access.

From the repository root in PowerShell:

```powershell
./scripts/test-local.ps1
```

The script builds the image and starts a disposable PostgreSQL container plus Mattermost on `127.0.0.1:18065`. It uses the Compose project `mattermost-10-12-4-test` and only that project's temporary volumes. It refuses to start if containers, volumes, or networks for that project already exist. It provisions a random disposable user, team, channel, and access token using local `mmctl`; then it posts through the REST API and checks the returned post, channel, and user IDs. It never reads production credentials. After checks, it runs `docker compose down --volumes --remove-orphans` for that project and exits non-zero if cleanup fails. The built image remains locally tagged `mattermost-custom:10.12.4-audit`.

The script checks:

1. `/api/v4/system/ping` returns `status: OK`.
2. `mattermost version` reports `10.12.4` and build hash `463e0d0d3930782d3c975da26c991dcbfccd751c`.
3. `POST /api/v4/posts` returns HTTP 201, and the returned IDs match the disposable user and channel. The generated password and token are not printed.

Equivalent guarded direct image build command (without starting containers):

```powershell
if ((git rev-parse company-baseline-10.12.4) -ne '463e0d0d3930782d3c975da26c991dcbfccd751c') {
  throw 'The source-of-truth tag does not match the pinned Mattermost revision.'
}
foreach ($path in @('server', 'webapp', 'README.md', 'NOTICE.txt')) {
  if ((git rev-parse "463e0d0d3930782d3c975da26c991dcbfccd751c`:$path") -ne (git rev-parse "HEAD:$path")) {
    throw "Build input $path differs from the baseline tree."
  }
}
git diff --quiet 463e0d0d3930782d3c975da26c991dcbfccd751c -- server webapp README.md NOTICE.txt
if ($LASTEXITCODE -ne 0) { throw 'Mattermost source or release metadata has local changes.' }
if (@(git ls-files --others --exclude-standard -- server webapp).Count -gt 0) {
  throw 'Untracked files under server/ or webapp/ contaminate the source build.'
}

docker build --platform linux/amd64 `
  --build-arg MATTERMOST_VERSION=10.12.4 `
  --build-arg SOURCE_REVISION=463e0d0d3930782d3c975da26c991dcbfccd751c `
  -t mattermost-custom:10.12.4-audit `
  -f Dockerfile.custom .
```

The official package target cleans and recreates `server/dist`; it runs inside the temporary build stage, not in the working tree. The same verification is applied by `scripts/test-local.ps1` before Compose builds.

## Future deployment template

`deploy/docker-compose.yml` is a future production cutover template only. **Do not run `docker compose up`, `down`, or other lifecycle commands with it casually:** it deliberately uses the existing production project, network, and external volumes. It expects `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `MM_SQLSETTINGS_DATASOURCE`, and `MM_SERVICESETTINGS_SITEURL` from the future deployment environment. `MM_SQLSETTINGS_DATASOURCE` must be a complete PostgreSQL URL whose password component is URL-encoded; keep `POSTGRES_PASSWORD` raw for PostgreSQL initialization. Do not commit a populated `.env` file.

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
