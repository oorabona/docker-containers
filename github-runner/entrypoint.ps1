#Requires -Version 5.1
<#
.SYNOPSIS
    GitHub Actions self-hosted runner entrypoint for Windows containers.

.DESCRIPTION
    Registers an ephemeral self-hosted runner with GitHub (via PAT or GitHub App),
    runs one job, then deregisters and exits. Mirrors entrypoint.sh logic.

.ENVIRONMENT
    RUNNER_TOKEN          - Direct registration token from GitHub UI (expires in 1h; mutually exclusive with GITHUB_TOKEN / APP_*)
    GITHUB_TOKEN          - PAT with repo/admin:org scope (mutually exclusive with RUNNER_TOKEN / APP_*)
    APP_ID                - GitHub App ID
    APP_PRIVATE_KEY       - GitHub App RSA private key (PEM string, literal \n supported)
    APP_PRIVATE_KEY_FILE  - Path to GitHub App PEM file (alternative to APP_PRIVATE_KEY)
    GITHUB_REPOSITORY     - owner/repo (mutually exclusive with GITHUB_ORG)
    GITHUB_ORG            - Organisation name (mutually exclusive with GITHUB_REPOSITORY)
    GITHUB_API_URL        - API base URL (default: https://api.github.com)
    RUNNER_NAME_PREFIX    - Prefix for the unique runner name (default: runner)
    RUNNER_LABELS         - Comma-separated labels (default: self-hosted,windows,x64)
    RUNNER_GROUP          - Runner group (default: Default)
    RUNNER_TOOL_CACHE     - Tool cache directory (default: C:\cache\tool-cache)
    RUNNER_DISABLE_AUTO_UPDATE - Disable agent auto-update (default: 1)
    ALLOW_ROOT            - Set to "true" to allow running as SYSTEM / ContainerAdministrator
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO]  $Message"
}

function Write-Warn {
    param([string]$Message)
    Write-Warning "[WARN]  $Message"
}

function Write-Err {
    param([string]$Message)
    [Console]::Error.WriteLine("[ERROR] $Message")
}

# ---------------------------------------------------------------------------
# Function: Test-RootCheck
# Blocks execution when the process is running as SYSTEM or
# ContainerAdministrator unless ALLOW_ROOT is explicitly set to "true".
# ---------------------------------------------------------------------------
function Test-RootCheck {
    $allowRoot = $env:ALLOW_ROOT
    if ($allowRoot -ieq 'true') {
        return
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)

    # Only block SYSTEM (S-1-5-18) -- running as ContainerAdministrator or
    # a member of Administrators is normal for Windows containers.
    $isSystem = $identity.User.Value -eq 'S-1-5-18'

    if ($isSystem) {
        Write-Err "Running as SYSTEM is not supported."
        Write-Err "Set ALLOW_ROOT=true to override."
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Function: New-JWT
# Generates an RS256 JWT for GitHub App authentication using .NET crypto.
#
# Parameters:
#   AppId      - GitHub App ID (becomes the "iss" claim)
#   KeyPemPath - Path to a PEM file containing the RSA private key
#
# Returns: JWT string (header.payload.signature, URL-safe base64)
# ---------------------------------------------------------------------------
function New-JWT {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$AppId,
        [Parameter(Mandatory)][string]$KeyPemPath
    )

    # --- Build header + payload -------------------------------------------
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $iat = $now - 60          # 60s clock skew buffer
    $exp = $now + 540         # 9-minute lifetime (GitHub max is 10 min)

    $headerJson  = '{"alg":"RS256","typ":"JWT"}'
    $payloadJson = '{"iat":' + $iat + ',"exp":' + $exp + ',"iss":"' + $AppId + '"}'

    $header  = ConvertTo-JwtBase64 ([Text.Encoding]::UTF8.GetBytes($headerJson))
    $payload = ConvertTo-JwtBase64 ([Text.Encoding]::UTF8.GetBytes($payloadJson))

    $signingInput = $header + '.' + $payload

    # --- Load RSA key -------------------------------------------------------
    $pemContent = Get-Content -Raw $KeyPemPath

    # Strip PEM armour and decode the DER bytes
    $base64Key = $pemContent `
        -replace '-----BEGIN (RSA )?PRIVATE KEY-----', '' `
        -replace '-----END (RSA )?PRIVATE KEY-----',   '' `
        -replace '\s', ''
    $keyBytes = [Convert]::FromBase64String($base64Key)

    # --- Sign with RSA-SHA256 -----------------------------------------------
    $rsa = [Security.Cryptography.RSA]::Create()
    try {
        # ImportRSAPrivateKey requires .NET 5+ / PS 7+.
        # On Windows PowerShell 5.1 (Server 2022 default), use CryptoAPI via
        # RSACryptoServiceProvider with PKCS#8 / PKCS#1 import.
        if ($rsa -is [Security.Cryptography.RSACryptoServiceProvider]) {
            # Windows PowerShell 5.1 path
            $rsa.ImportCspBlob((ConvertFrom-Pkcs8ToCsp $keyBytes))
        } else {
            # PowerShell 7+ path (.NET 5+)
            try {
                $rsa.ImportRSAPrivateKey($keyBytes, [ref]$null)
            } catch {
                # Fall back to PKCS#8 format
                $rsa.ImportPkcs8PrivateKey($keyBytes, [ref]$null)
            }
        }

        $inputBytes = [Text.Encoding]::ASCII.GetBytes($signingInput)
        $sigBytes   = $rsa.SignData(
            $inputBytes,
            [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1
        )
    } finally {
        $rsa.Dispose()
    }

    $sig = ConvertTo-JwtBase64 $sigBytes
    return $signingInput + '.' + $sig
}

# ---------------------------------------------------------------------------
# Helper: ConvertTo-JwtBase64
# URL-safe base64 without padding (RFC 4648 §5).
# ---------------------------------------------------------------------------
function ConvertTo-JwtBase64 {
    [OutputType([string])]
    param([byte[]]$Bytes)
    [Convert]::ToBase64String($Bytes) `
        -replace '\+', '-' `
        -replace '/',  '_' `
        -replace '=+$', ''
}

# ---------------------------------------------------------------------------
# Helper: ConvertFrom-Pkcs8ToCsp
# Converts a PKCS#8 DER key blob to a CspBlob that RSACryptoServiceProvider
# can import via ImportCspBlob on Windows PowerShell 5.1.
# This is a thin wrapper; on modern .NET the import path is used instead.
# ---------------------------------------------------------------------------
function ConvertFrom-Pkcs8ToCsp {
    param([byte[]]$Pkcs8Bytes)
    # Create a temporary CNG key then export as CAPI CSP blob
    $cng = [Security.Cryptography.CngKey]::Import(
        $Pkcs8Bytes,
        [Security.Cryptography.CngKeyBlobFormat]::Pkcs8PrivateBlob
    )
    $rsaCng = [Security.Cryptography.RSACng]::new($cng)
    $params  = $rsaCng.ExportParameters($true)   # include private components
    $csp     = [Security.Cryptography.RSACryptoServiceProvider]::new()
    $csp.ImportParameters($params)
    return $csp.ExportCspBlob($true)
}

# ---------------------------------------------------------------------------
# Function: Get-RegistrationToken
# Calls the GitHub API to obtain an ephemeral runner registration token.
# Retries up to 5 times with exponential backoff (2 → 4 → 8 → 16 → 32 s).
# Respects the Retry-After header on HTTP 429 responses.
#
# Parameters:
#   AuthToken - Bearer / PAT token for the Authorization header
#   ApiUrl    - Full URL for the registration-token endpoint
#
# Returns: registration token string on success; exits 1 on final failure.
# ---------------------------------------------------------------------------
function Get-RegistrationToken {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$AuthToken,
        [Parameter(Mandatory)][string]$ApiUrl
    )

    $maxAttempts = 5
    $delay       = 2

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $response = Invoke-WebRequest `
                -Uri     $ApiUrl `
                -Method  POST `
                -Headers @{
                    Authorization = "token $AuthToken"
                    Accept        = 'application/vnd.github+json'
                } `
                -UseBasicParsing `
                -ErrorAction Stop

            $token = ($response.Content | ConvertFrom-Json).token
            if (-not $token) {
                throw "Response did not contain a token field."
            }
            return $token

        } catch [Net.WebException] {
            $webEx    = $_.Exception
            $httpCode = if ($webEx.Response) { [int]$webEx.Response.StatusCode } else { 0 }

            # Honour Retry-After on rate-limit responses
            if ($httpCode -eq 429) {
                $retryAfter = $webEx.Response.Headers['Retry-After']
                if ($retryAfter -match '^\d+$') {
                    $delay = [int]$retryAfter
                    Write-Warn "Rate-limited (HTTP 429) -- Retry-After: ${delay}s"
                }
            }

            Write-Warn "Attempt $attempt/$maxAttempts failed (HTTP $httpCode) -- retry in ${delay}s"

        } catch {
            Write-Warn "Attempt $attempt/$maxAttempts failed: $($_.Exception.Message) -- retry in ${delay}s"
        }

        if ($attempt -lt $maxAttempts) {
            Start-Sleep -Seconds $delay
            $delay = [Math]::Min($delay * 2, 32)
        }
    }

    Write-Err "Failed to obtain registration token after $maxAttempts attempts"
    exit 1
}

# ---------------------------------------------------------------------------
# Function: Register-Runner
# Calls .\config.cmd to register this runner with GitHub.
# On name conflict (exit code 3), retries with --replace.
# ---------------------------------------------------------------------------
function Register-Runner {
    param(
        [Parameter(Mandatory)][string]$RegistrationToken,
        [Parameter(Mandatory)][string]$RunnerUrl,
        [Parameter(Mandatory)][string]$RunnerName,
        [Parameter(Mandatory)][string]$RunnerLabels,
        [Parameter(Mandatory)][string]$RunnerGroup
    )

    $configArgs = @(
        '--url',         $RunnerUrl,
        '--token',       $RegistrationToken,
        '--name',        $RunnerName,
        '--labels',      $RunnerLabels,
        '--runnergroup', $RunnerGroup,
        '--ephemeral',
        '--unattended'
    )

    Write-Info "Registering runner '$RunnerName' against $RunnerUrl ..."
    & '.\config.cmd' @configArgs
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 3) {
        Write-Warn "Runner name conflict (exit 3) -- retrying with --replace"
        & '.\config.cmd' @configArgs '--replace'
        $exitCode = $LASTEXITCODE
    }

    if ($exitCode -ne 0) {
        Write-Err "config.cmd exited with code $exitCode -- registration failed"
        exit $exitCode
    }

    Write-Info "Runner registered successfully."
}

# ---------------------------------------------------------------------------
# Function: Remove-Runner
# Calls .\config.cmd remove to deregister the runner gracefully.
# Silently ignores failures (best-effort cleanup on shutdown).
# ---------------------------------------------------------------------------
function Remove-Runner {
    param([Parameter(Mandatory)][string]$RegistrationToken)

    Write-Info "Deregistering runner ..."
    try {
        & '.\config.cmd' remove --token $RegistrationToken 2>$null
    } catch {
        Write-Warn "Deregistration attempt failed (non-fatal): $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Function: Resolve-PemFile
# Returns a path to a temporary PEM file for the RSA private key.
# Handles three cases:
#   1. APP_PRIVATE_KEY_FILE env var -- use directly
#   2. APP_PRIVATE_KEY env var with literal \n -- expand and write temp file
#   3. APP_PRIVATE_KEY env var with real newlines -- write temp file
# ---------------------------------------------------------------------------
function Resolve-PemFile {
    [OutputType([string])]
    param()

    if ($env:APP_PRIVATE_KEY_FILE) {
        if (-not (Test-Path $env:APP_PRIVATE_KEY_FILE)) {
            Write-Err "APP_PRIVATE_KEY_FILE '$($env:APP_PRIVATE_KEY_FILE)' does not exist"
            exit 1
        }
        return $env:APP_PRIVATE_KEY_FILE
    }

    if (-not $env:APP_PRIVATE_KEY) {
        Write-Err "APP_PRIVATE_KEY or APP_PRIVATE_KEY_FILE must be set when using GitHub App auth"
        exit 1
    }

    # Expand literal \n sequences (common when passing PEM via env var in YAML)
    $pem = $env:APP_PRIVATE_KEY -replace '\\n', "`n"

    $tmpFile = [IO.Path]::GetTempFileName() + '.pem'
    Set-Content -Path $tmpFile -Value $pem -NoNewline
    return $tmpFile
}

# ---------------------------------------------------------------------------
# Function: Get-AuthToken
# Resolves the bearer token used to call the registration-token endpoint.
# Supports PAT (GITHUB_TOKEN) and GitHub App (APP_ID + APP_PRIVATE_KEY[_FILE]).
# ---------------------------------------------------------------------------
function Get-AuthToken {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ApiBase,
        [Parameter(Mandatory)][string]$Scope   # "repos/owner/repo" or "orgs/myorg"
    )

    # --- PAT path -----------------------------------------------------------
    if ($env:GITHUB_TOKEN) {
        Write-Info "Using PAT authentication."
        return $env:GITHUB_TOKEN
    }

    # --- GitHub App path ----------------------------------------------------
    if (-not $env:APP_ID) {
        Write-Err "Must set RUNNER_TOKEN, GITHUB_TOKEN, or APP_ID+APP_PRIVATE_KEY[_FILE] for authentication."
        exit 1
    }

    Write-Info "Using GitHub App authentication (APP_ID=$($env:APP_ID))."

    $pemFile    = Resolve-PemFile
    $tmpCreated = ($pemFile -ne $env:APP_PRIVATE_KEY_FILE)

    try {
        $jwt = New-JWT -AppId $env:APP_ID -KeyPemPath $pemFile

        # Get installation ID
        $installResponse = Invoke-WebRequest `
            -Uri     "$ApiBase/$Scope/installation" `
            -Headers @{
                Authorization = "Bearer $jwt"
                Accept        = 'application/vnd.github+json'
            } `
            -UseBasicParsing `
            -ErrorAction Stop

        $installId = ($installResponse.Content | ConvertFrom-Json).id
        Write-Info "GitHub App installation ID: $installId"

        # Exchange for an installation access token
        $tokenResponse = Invoke-WebRequest `
            -Uri     "$ApiBase/app/installations/$installId/access_tokens" `
            -Method  POST `
            -Headers @{
                Authorization = "Bearer $jwt"
                Accept        = 'application/vnd.github+json'
            } `
            -UseBasicParsing `
            -ErrorAction Stop

        return ($tokenResponse.Content | ConvertFrom-Json).token

    } finally {
        if ($tmpCreated -and (Test-Path $pemFile)) {
            Remove-Item $pemFile -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# Function: Initialize-CacheDirectories
# Ensures RUNNER_TOOL_CACHE and well-known cache directories exist and are
# writable. Warns (non-fatal) when a directory exists but cannot be written.
# ---------------------------------------------------------------------------
function Initialize-CacheDirectories {
    $dirs = @(
        $env:RUNNER_TOOL_CACHE,
        "$env:USERPROFILE\.cargo",
        "$env:USERPROFILE\.npm",
        "$env:USERPROFILE\.nuget",
        "$env:USERPROFILE\.pnpm-store"
    )

    foreach ($dir in $dirs) {
        if (-not $dir) { continue }

        if (-not (Test-Path $dir)) {
            try {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                Write-Info "Created cache directory: $dir"
            } catch {
                Write-Warn "Could not create cache directory '$dir': $($_.Exception.Message)"
            }
            continue
        }

        # Probe writability
        $probe = Join-Path $dir ".write-test-$PID"
        try {
            [IO.File]::WriteAllText($probe, '')
            Remove-Item $probe -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Warn "Cache directory '$dir' exists but is not writable: $($_.Exception.Message)"
        }
    }
}

# ===========================================================================
# MAIN -- guarded so the file can be dot-sourced by Pester tests
# ===========================================================================

# When dot-sourced (e.g. `. ./entrypoint.ps1` from a test), InvocationName is '.'
# and the main block is skipped -- only the function definitions are loaded.
if ($MyInvocation.InvocationName -ne '.') {

# 0. Root / privilege check
Test-RootCheck

# 0.5. Disable runner auto-update (prevents crash loop when the agent self-updates
#      inside an ephemeral container that won't persist the update).
$env:RUNNER_DISABLE_AUTO_UPDATE = if ($env:RUNNER_DISABLE_AUTO_UPDATE) {
    $env:RUNNER_DISABLE_AUTO_UPDATE
} else { '1' }

# 0.6. Initialise cache directories
$env:RUNNER_TOOL_CACHE = if ($env:RUNNER_TOOL_CACHE) {
    $env:RUNNER_TOOL_CACHE
} else { 'C:\cache\tool-cache' }

Initialize-CacheDirectories

# 1. Validate required env vars and derive scope / URL
$apiBase = if ($env:GITHUB_API_URL) { $env:GITHUB_API_URL.TrimEnd('/') } else { 'https://api.github.com' }

if ($env:GITHUB_REPOSITORY) {
    $scope      = "repos/$($env:GITHUB_REPOSITORY)"
    $runnerUrl  = "https://github.com/$($env:GITHUB_REPOSITORY)"
} elseif ($env:GITHUB_ORG) {
    $scope      = "orgs/$($env:GITHUB_ORG)"
    $runnerUrl  = "https://github.com/$($env:GITHUB_ORG)"
} else {
    Write-Err "Must set GITHUB_REPOSITORY (owner/repo) or GITHUB_ORG."
    exit 1
}

$namePrefix  = if ($env:RUNNER_NAME_PREFIX)  { $env:RUNNER_NAME_PREFIX }  else { 'runner' }
$labels      = if ($env:RUNNER_LABELS)       { $env:RUNNER_LABELS }       else { 'self-hosted,windows,x64' }
$group       = if ($env:RUNNER_GROUP)        { $env:RUNNER_GROUP }        else { 'Default' }

# Generate a unique runner name: <prefix>-<hostname>-<epoch>
$epoch       = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$runnerName  = "$namePrefix-$($env:COMPUTERNAME)-$epoch"

Write-Info "Runner name : $runnerName"
Write-Info "Runner URL  : $runnerUrl"
Write-Info "Labels      : $labels"
Write-Info "Group       : $group"
Write-Info "API base    : $apiBase"
Write-Info "Tool cache  : $($env:RUNNER_TOOL_CACHE)"

# 2. Obtain registration token
# RUNNER_TOKEN path: the env var IS the registration token -- skip API auth entirely
if ($env:RUNNER_TOKEN) {
    Write-Info "Using direct registration token (RUNNER_TOKEN) -- skipping API auth."
    $script:RegToken = $env:RUNNER_TOKEN
} else {
    # PAT or GitHub App path: exchange for a registration token via the API
    $authToken = Get-AuthToken -ApiBase $apiBase -Scope $scope
    $regTokenUrl = "$apiBase/$scope/actions/runners/registration-token"
    $script:RegToken = Get-RegistrationToken -AuthToken $authToken -ApiUrl $regTokenUrl
}

# 4. Change to runner working directory
Set-Location 'C:\actions-runner'

# 5. Register the runner
Register-Runner `
    -RegistrationToken $script:RegToken `
    -RunnerUrl         $runnerUrl `
    -RunnerName        $runnerName `
    -RunnerLabels      $labels `
    -RunnerGroup       $group

# 6. Signal handling -- deregister on PowerShell engine exit and on Ctrl+C
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    Write-Host "[INFO]  PowerShell engine exiting -- deregistering runner"
    try {
        & 'C:\actions-runner\config.cmd' remove --token $script:RegToken 2>$null
    } catch {
        # Best-effort; ignore failures during shutdown
    }
}

[Console]::TreatControlCAsInput = $false
$null = [Console]::CancelKeyPress.Add({
    param($sender, $e)
    $e.Cancel = $true   # Prevent immediate SIGINT termination; let finally block run
    Write-Host "[INFO]  Ctrl+C received -- requesting graceful shutdown"
})

# 7. Run the runner agent -- blocks until the job completes (--ephemeral exits after one job)
Write-Info "Starting runner agent ..."

try {
    $process = Start-Process `
        -FilePath    '.\run.cmd' `
        -NoNewWindow `
        -PassThru    `
        -ErrorAction Stop

    $process.WaitForExit()
    $exitCode = $process.ExitCode
    Write-Info "Runner agent exited with code $exitCode"

} finally {
    # 8. Cleanup -- runs on any exit path (normal, exception, signal).
    # When using RUNNER_TOKEN the removal token is unavailable (no bearer token to
    # re-call the API).  Remove-Runner is called best-effort; it will warn if it fails.
    Remove-Runner -RegistrationToken $script:RegToken
}

exit $exitCode

} # end if ($MyInvocation.InvocationName -ne '.')
