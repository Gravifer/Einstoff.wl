param(
    [switch] $Python,
    [string] $ExpectedTag
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'retry-python-tests.ps1')

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

    $previousArchive = $env:EINSTOFF_TEST_PACLET_ARCHIVE
    try {
        $env:EINSTOFF_TEST_PACLET_ARCHIVE = $archive
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
    Pop-Location
}
