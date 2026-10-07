[CmdletBinding()]
param(
    [int]$StartupTimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'
$Project = 'mattermost-10-12-4-test'
$BaselineRef = 'company-baseline-10.12.4'
$SourceRevision = '463e0d0d3930782d3c975da26c991dcbfccd751c'
$BuildDate = '2025-11-21T13:22:45Z'
$ComposeFile = Join-Path $PSScriptRoot '..\deploy\docker-compose.test.yml'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$BaseUrl = 'http://127.0.0.1:18065'
$Compose = @('compose', '-p', $Project, '-f', $ComposeFile)
$Started = $false

function Invoke-LocalMmctl {
    param([string[]]$Arguments)

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& docker @Compose exec -T mattermost /mattermost/bin/mmctl --local @Arguments 2>&1)
        $commandExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($commandExitCode -ne 0) {
        $commandName = if ($Arguments.Count -gt 1) { $Arguments[0..1] -join ' ' } else { $Arguments -join ' ' }
        throw "Local mmctl command '$commandName' failed with exit code $commandExitCode. Output is suppressed to avoid exposing generated credentials."
    }
    return ($output -join "`n")
}

Push-Location $RepoRoot
try {
    $actualBaseline = (& git rev-parse $BaselineRef).Trim()
    if ($LASTEXITCODE -ne 0 -or $actualBaseline -ne $SourceRevision) {
        throw "Expected $BaselineRef to resolve to $SourceRevision; found '$actualBaseline'."
    }

    foreach ($path in @('server', 'webapp', 'README.md', 'NOTICE.txt')) {
        $baselineTree = (& git rev-parse "${SourceRevision}:$path").Trim()
        if ($LASTEXITCODE -ne 0) { throw "Unable to read baseline tree for '$path'." }
        $headTree = (& git rev-parse "HEAD:$path").Trim()
        if ($LASTEXITCODE -ne 0 -or $headTree -ne $baselineTree) {
            throw "Build input '$path' does not match $BaselineRef ($SourceRevision)."
        }
        & git diff --quiet $SourceRevision -- $path
        if ($LASTEXITCODE -ne 0) { throw "Working-tree changes detected in build input '$path'." }
        & git diff --cached --quiet $SourceRevision -- $path
        if ($LASTEXITCODE -ne 0) { throw "Staged changes detected in build input '$path'." }
    }

    $untrackedSource = @(& git ls-files --others --exclude-standard -- server webapp)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect untracked Mattermost source files.' }
    if ($untrackedSource.Count -gt 0) {
        throw "Untracked files under server/ or webapp/ would contaminate the source build: $($untrackedSource -join ', ')"
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
    & docker @Compose build --build-arg "SOURCE_REVISION=$SourceRevision" --build-arg "BUILD_DATE=$BuildDate" mattermost
    if ($LASTEXITCODE -ne 0) { throw 'Docker Compose image build failed.' }
    & docker @Compose up --detach
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

    $testId = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $username = "apitest$testId"
    $email = "$username@example.invalid"
    $teamName = "mmtest$testId"
    $channelName = "apitest$testId"
    $randomBytes = New-Object byte[] 24
    $randomGenerator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $randomGenerator.GetBytes($randomBytes) } finally { $randomGenerator.Dispose() }
    $testPassword = [Convert]::ToBase64String($randomBytes) + 'aA1!'

    Invoke-LocalMmctl @('user', 'create', '--email', $email, '--username', $username,
        '--password', $testPassword, '--email-verified', '--disable-welcome-email') | Out-Null
    $testPassword = $null
    Invoke-LocalMmctl @('team', 'create', '--name', $teamName, '--display-name', "API Test $testId") | Out-Null
    Invoke-LocalMmctl @('team', 'users', 'add', $teamName, $username) | Out-Null
    Invoke-LocalMmctl @('channel', 'create', '--team', $teamName, '--name', $channelName,
        '--display-name', "API Test $testId") | Out-Null
    Invoke-LocalMmctl @('channel', 'users', 'add', "${teamName}:$channelName", $username) | Out-Null

    $tokenOutput = Invoke-LocalMmctl @('token', 'generate', $username, "api-post-$testId")
    $tokenMatch = [regex]::Match($tokenOutput, "(?m)^\s*(\S+):\s+api-post-$testId\s*$")
    if (-not $tokenMatch.Success) { throw 'Could not parse the disposable API token from local mmctl output.' }
    $token = $tokenMatch.Groups[1].Value
    $headers = @{ Authorization = "Bearer $token" }

    $testUser = Invoke-RestMethod -Uri "$BaseUrl/api/v4/users/me" -Headers $headers -TimeoutSec 30
    $testChannel = Invoke-RestMethod -Uri "$BaseUrl/api/v4/teams/name/$teamName/channels/name/$channelName" `
        -Headers $headers -TimeoutSec 30
    if ([string]::IsNullOrWhiteSpace($testUser.id) -or [string]::IsNullOrWhiteSpace($testChannel.id)) {
        throw 'Local provisioning did not return user and channel IDs.'
    }

    $postBody = @{
        channel_id = $testChannel.id
        message = "Local Mattermost API compatibility test $testId"
    } | ConvertTo-Json -Compress
    Add-Type -AssemblyName System.Net.Http
    $httpClient = [System.Net.Http.HttpClient]::new()
    $httpClient.Timeout = [TimeSpan]::FromSeconds(30)
    $httpRequest = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::Post, "$BaseUrl/api/v4/posts")
    $httpRequest.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
    $httpRequest.Content = [System.Net.Http.StringContent]::new(
        $postBody, [System.Text.Encoding]::UTF8, 'application/json')
    try {
        $postResponse = $httpClient.SendAsync($httpRequest).GetAwaiter().GetResult()
        $postStatusCode = [int]$postResponse.StatusCode
        $postContent = $postResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    } finally {
        if ($postResponse) { $postResponse.Dispose() }
        $httpRequest.Dispose()
        $httpClient.Dispose()
    }
    if ($postStatusCode -ne 201) {
        throw "POST /api/v4/posts returned HTTP $postStatusCode, expected 201."
    }
    $createdPost = $postContent | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($createdPost.id) -or
        $createdPost.channel_id -ne $testChannel.id -or $createdPost.user_id -ne $testUser.id) {
        throw 'POST /api/v4/posts response did not contain matching post, channel, and user IDs.'
    }
    Write-Host "PASS: POST /api/v4/posts created post ID $($createdPost.id) for disposable channel ID $($createdPost.channel_id) and user ID $($createdPost.user_id)."

    $versionOutput = (& docker @Compose exec -T mattermost /mattermost/bin/mattermost version 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "Mattermost version command failed: $versionOutput" }
    if ($versionOutput -notmatch '(?m)^Version:\s+10\.12\.4\s*$') {
        throw "Mattermost did not report version 10.12.4:`n$versionOutput"
    }
    if ($versionOutput -notmatch "(?m)^Build Hash:\s+$SourceRevision\s*$") {
        throw "Mattermost build hash does not match ${SourceRevision}:`n$versionOutput"
    }
    Write-Host 'PASS: Mattermost reports version 10.12.4 and the pinned source revision.'

} finally {
    try {
        if ($Started) {
            & docker @Compose down --volumes --remove-orphans
            if ($LASTEXITCODE -ne 0) {
                throw "Cleanup of disposable project '$Project' failed with exit code $LASTEXITCODE."
            }
        }
    } finally {
        Pop-Location
    }
}
