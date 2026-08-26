param(
    [switch] $Python,
    [string] $ExpectedTag
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'retry-python-tests.ps1')
$compatibilityRoot = Join-Path ([IO.Path]::GetTempPath()) ("einstoff-spf-compatibility-" + [Guid]::NewGuid().ToString('N'))
$previousSourceRoot = $env:EINSTOFF_SOURCE_ROOT
$previousTestPython = $env:EINSTOFF_TEST_PYTHON

function Invoke-WolframScript {
    param([Parameter(Mandatory)] [string[]] $Arguments)

    & wolframscript @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "wolframscript failed with exit code ${LASTEXITCODE}: $($Arguments -join ' ')"
    }
}

Push-Location $root
try {
    Invoke-WolframScript -Arguments @('-script', 'scripts/generate-paclet-docs.wls')

    New-Item -ItemType Directory -Path $compatibilityRoot | Out-Null
    $pythonVersion = (Get-Content -LiteralPath '.python-version' -Raw).Trim()
    $transformArguments = @(
        'run'
        '--no-project'
        '--managed-python'
        '--python'
        $pythonVersion
        'python'
        'scripts/prepare-legacy-spf.py'
        '--source'
        $root
        '--output'
        $compatibilityRoot
    )
    & uv @transformArguments
    if ($LASTEXITCODE -ne 0) {
        throw "SPF compatibility staging failed with exit code $LASTEXITCODE."
    }
    $env:EINSTOFF_SOURCE_ROOT = $compatibilityRoot

    $sourceValidationArguments = @('-script', 'scripts/validate-paclet-source.wls')
    if ($ExpectedTag) {
        $sourceValidationArguments += $ExpectedTag
    }
    Invoke-WolframScript -Arguments $sourceValidationArguments

    $buildOutput = & wolframscript -script scripts/build-paclet.wls
    if ($LASTEXITCODE -ne 0) {
        $buildOutput | Out-Host
        throw "Paclet build failed with exit code $LASTEXITCODE."
    }
    $buildOutput | Out-Host

    $archiveLine = $buildOutput | Where-Object { $_ -like 'PACLET_ARCHIVE=*' } | Select-Object -Last 1
    if (-not $archiveLine) {
        throw 'The paclet build did not report an archive path.'
    }

    $archive = $archiveLine.Substring('PACLET_ARCHIVE='.Length)
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
        throw "The reported paclet archive does not exist: $archive"
    }

    $publishedBuild = Join-Path $root 'build'
    New-Item -ItemType Directory -Path $publishedBuild -Force | Out-Null
    $publishedArchive = Join-Path $publishedBuild (Split-Path -Leaf $archive)
    Copy-Item -LiteralPath $archive -Destination $publishedArchive -Force
    $manifestCopy = @{
        LiteralPath = Join-Path $compatibilityRoot 'spf-compatibility-manifest.json'
        Destination = Join-Path $publishedBuild 'spf-compatibility-manifest.json'
        Force = $true
    }
    Copy-Item @manifestCopy
    $archive = $publishedArchive

    $previousArchive = $env:EINSTOFF_TEST_PACLET_ARCHIVE
    try {
        $env:EINSTOFF_TEST_PACLET_ARCHIVE = $archive
        if ($Python -and -not $env:EINSTOFF_TEST_PYTHON) {
            $env:EINSTOFF_TEST_PYTHON = Join-Path $root '.venv\Scripts\python.exe'
        }
        Invoke-WolframScript -Arguments @('-script', 'scripts/run-tests.wls', '-q')
        if ($Python) {
            $pythonTestArguments = @('-script', 'scripts/run-tests.wls', 'python', '-q')
            Invoke-WithPythonStartupRetries -Operation {
                & wolframscript @pythonTestArguments | Out-Host
                $LASTEXITCODE
            }
        }
    }
    finally {
        $env:EINSTOFF_TEST_PACLET_ARCHIVE = $previousArchive
    }
}
finally {
    $env:EINSTOFF_SOURCE_ROOT = $previousSourceRoot
    $env:EINSTOFF_TEST_PYTHON = $previousTestPython
    $resolvedCompatibilityRoot = [IO.Path]::GetFullPath($compatibilityRoot)
    $resolvedTemporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $resolvedTemporaryPrefix = $resolvedTemporaryRoot.TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
    if (
        (Test-Path -LiteralPath $resolvedCompatibilityRoot) -and
        $resolvedCompatibilityRoot.StartsWith($resolvedTemporaryPrefix, [StringComparison]::OrdinalIgnoreCase)
    ) {
        Remove-Item -LiteralPath $resolvedCompatibilityRoot -Recurse -Force
    }
    Pop-Location
}
