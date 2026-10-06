param(
    [string] $Relay,
    [string] $Config = (Join-Path $HOME '.config/hermes-harmony/connection.json'),
    [Parameter(ValueFromRemainingArguments = $true)] [string[]] $ConnectorArgs
)
$ErrorActionPreference = 'Stop'
$ReleaseTag = 'v0.6.8'
$ReleaseUrl = "https://github.com/topyang519/hermes-harmony/releases/download/$ReleaseTag"
$Wheel = 'hermes_harmony_bridge-0.3.8-py3-none-any.whl'

$CliArgs = @('--config', $Config)
if ($Relay) { $CliArgs += @('--relay', $Relay) }
if ($ConnectorArgs) { $CliArgs += $ConnectorArgs }
if (-not $Relay -and -not (Test-Path -LiteralPath $Config -PathType Leaf)) {
    throw 'First install requires -Relay wss://your-deployed-relay.example'
}

$Python = Get-Command py -ErrorAction SilentlyContinue
if (-not $Python) { throw 'Python 3.11+ and the Windows py launcher are required.' }
$Version = & $Python.Source -3 --version 2>&1
if ($LASTEXITCODE -ne 0) { throw 'Python 3.11+ is required. Install it from python.org, then rerun this command.' }
if ($Version -notmatch 'Python\s+(\d+)\.(\d+)' -or [int]$Matches[1] -lt 3 -or ([int]$Matches[1] -eq 3 -and [int]$Matches[2] -lt 11)) {
    throw "Python 3.11+ is required; found: $Version"
}
$PythonArgs = @('-3')
$InstallDir = Join-Path $env:LOCALAPPDATA 'hermes-harmony'
$TempDir = Join-Path ([IO.Path]::GetTempPath()) ("hermes-harmony-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $TempDir | Out-Null
try {
    Invoke-WebRequest -Uri "$ReleaseUrl/SHA256SUMS" -OutFile (Join-Path $TempDir 'SHA256SUMS')
    Invoke-WebRequest -Uri "$ReleaseUrl/$Wheel" -OutFile (Join-Path $TempDir $Wheel)
    $ChecksumLine = Get-Content (Join-Path $TempDir 'SHA256SUMS') |
        Where-Object { $_ -match "^([0-9a-fA-F]{64})\s+\*?$([regex]::Escape($Wheel))$" } |
        Select-Object -First 1
    if (-not $ChecksumLine) { throw 'The release checksum manifest does not list the connector wheel.' }
    $Expected = [regex]::Match($ChecksumLine, '^[0-9a-fA-F]{64}').Value.ToLowerInvariant()
    $Actual = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $TempDir $Wheel)).Hash.ToLowerInvariant()
    if ($Expected -ne $Actual) { throw 'Connector wheel checksum verification failed.' }

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $Venv = Join-Path $InstallDir 'venv'
    if (-not (Test-Path (Join-Path $Venv 'Scripts/python.exe'))) {
        & $Python.Source @PythonArgs -m venv $Venv
        if ($LASTEXITCODE -ne 0) { throw 'Could not create the connector virtual environment.' }
    }
    $VenvPython = Join-Path $Venv 'Scripts/python.exe'
    & $VenvPython -m pip install --quiet --upgrade (Join-Path $TempDir $Wheel)
    if ($LASTEXITCODE -ne 0) { throw 'Connector installation failed.' }
    $Connector = Join-Path $Venv 'Scripts/hermes-harmony-connect.exe'
    & $Connector setup @CliArgs
    if ($LASTEXITCODE -ne 0) { throw 'Connector setup failed.' }
    Write-Host 'Windows keeps the connector running in this PowerShell window.'
    & $Connector run @CliArgs
    exit $LASTEXITCODE
}
finally {
    Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
}
