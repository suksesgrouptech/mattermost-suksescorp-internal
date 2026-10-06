[CmdletBinding()]
param(
    [int]$StartupTimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'
$Project = 'mattermost-10-12-4-test'
$SourceRevision = '463e0d0d3930782d3c975da26c991dcbfccd751c'
$ComposeFile = Join-Path $PSScriptRoot '..\deploy\docker-compose.test.yml'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$BaseUrl = 'http://127.0.0.1:18065'
$Compose = @('compose', '-p', $Project, '-f', $ComposeFile)
$Started = $false

Push-Location $RepoRoot
try {
    $actualRevision = (& git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $actualRevision -ne $SourceRevision) {
        throw "Expected source revision $SourceRevision; found '$actualRevision'."
    }

    & git diff --quiet $SourceRevision -- server webapp
    if ($LASTEXITCODE -ne 0) {
        throw 'Tracked files under server/ or webapp/ differ from the pinned source commit.'
    }

    $existingContainers = @(& docker @Compose ps --all --quiet)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect the local test Compose project.' }
    $existingVolumes = @(& docker volume ls --quiet --filter "label=com.docker.compose.project=$Project")
    if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect Docker volumes for the local test project.' }
    $existingNetworks = @(& docker network ls --quiet --filter "label=com.docker.compose.project=$Project")
    if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect Docker networks for the local test project.' }
    if ($existingContainers.Count -gt 0 -or $existingVolumes.Count -gt 0 -or $existingNetworks.Count -gt 0) {
        throw "Refusing to reuse existing Docker resources named for '$Project'. Remove or rename that disposable test project first."
    }

    $Started = $true
    & docker @Compose up --detach --build
    if ($LASTEXITCODE -ne 0) { throw 'Docker Compose build/start failed.' }

    $deadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)
    $ping = $null
    while ((Get-Date) -lt $deadline) {
        try {
            $ping = Invoke-RestMethod -Uri "$BaseUrl/api/v4/system/ping" -TimeoutSec 10
            if ($ping.status -eq 'OK') { break }
        } catch {
            # Mattermost may still be starting or applying its disposable DB migrations.
        }
        Start-Sleep -Seconds 5
    }
    if ($null -eq $ping -or $ping.status -ne 'OK') {
        throw "Mattermost did not return status OK from $BaseUrl/api/v4/system/ping within $StartupTimeoutSeconds seconds."
    }
    Write-Host 'PASS: GET /api/v4/system/ping returned OK.'

    $versionOutput = (& docker @Compose exec -T mattermost /mattermost/bin/mattermost version 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "Mattermost version command failed: $versionOutput" }
    if ($versionOutput -notmatch '(?m)^Version:\s+10\.12\.4\s*$') {
        throw "Mattermost did not report version 10.12.4:`n$versionOutput"
    }
    if ($versionOutput -notmatch "(?m)^Build Hash:\s+$SourceRevision\s*$") {
        throw "Mattermost build hash does not match ${SourceRevision}:`n$versionOutput"
    }
    Write-Host 'PASS: Mattermost reports version 10.12.4 and the pinned source revision.'

    $token = [Environment]::GetEnvironmentVariable('MM_TEST_BEARER_TOKEN')
    $channelId = [Environment]::GetEnvironmentVariable('MM_TEST_CHANNEL_ID')
    if ([string]::IsNullOrWhiteSpace($token) -and [string]::IsNullOrWhiteSpace($channelId)) {
        Write-Host 'SKIP: POST /api/v4/posts; set MM_TEST_BEARER_TOKEN and MM_TEST_CHANNEL_ID for a disposable local account/channel.'
    } elseif ([string]::IsNullOrWhiteSpace($token) -or [string]::IsNullOrWhiteSpace($channelId)) {
        throw 'Set both MM_TEST_BEARER_TOKEN and MM_TEST_CHANNEL_ID, or leave both unset.'
    } else {
        $headers = @{ Authorization = "Bearer $token" }
        $body = @{
            channel_id = $channelId
            message = 'Local Mattermost 10.12.4 custom image smoke test.'
        } | ConvertTo-Json -Compress
        $response = Invoke-WebRequest -Uri "$BaseUrl/api/v4/posts" -Method Post `
            -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 30
        if ([int]$response.StatusCode -ne 201) {
            throw "POST /api/v4/posts returned HTTP $([int]$response.StatusCode), expected 201."
        }
        Write-Host 'PASS: POST /api/v4/posts succeeded against the disposable local channel.'
    }
} finally {
    if ($Started) {
        & docker @Compose down --volumes --remove-orphans
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Cleanup of disposable project '$Project' failed; inspect only that project before removing leftovers."
        }
    }
    Pop-Location
}
