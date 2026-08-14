$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'retry-python-tests.ps1')

function Assert-Equal {
    param($Actual, $Expected, [string] $Label)
    if ($Actual -ne $Expected) {
        throw "${Label}: expected ${Expected}, got ${Actual}."
    }
}

function Invoke-Scenario {
    param(
        [Parameter(Mandatory)] [int[]] $Statuses,
        [Parameter(Mandatory)] [int] $ExpectedCalls,
        [Parameter(Mandatory)] [int] $ExpectedStatus
    )

    $script:statusQueue = [System.Collections.Generic.Queue[int]]::new()
    foreach ($status in $Statuses) {
        $script:statusQueue.Enqueue($status)
    }
    $script:operationCalls = 0
    $actualStatus = 0
    try {
        Invoke-WithPythonStartupRetries -DelaySeconds 0 -Operation {
            $script:operationCalls++
            $script:statusQueue.Dequeue()
        }
    }
    catch {
        if ($_.Exception.Message -match 'exit code (?<status>\d+)') {
            $actualStatus = [int] $Matches.status
        }
        elseif ($_.Exception.Message -match 'startup failed after') {
            $actualStatus = 75
        }
        else {
            throw
        }
    }

    Assert-Equal $script:operationCalls $ExpectedCalls 'operation call count'
    Assert-Equal $actualStatus $ExpectedStatus 'result status'
}

Invoke-Scenario -Statuses @(0) -ExpectedCalls 1 -ExpectedStatus 0
Invoke-Scenario -Statuses @(75, 75, 0) -ExpectedCalls 3 -ExpectedStatus 0
Invoke-Scenario -Statuses @(75, 75, 75, 75) -ExpectedCalls 4 -ExpectedStatus 75
Invoke-Scenario -Statuses @(1) -ExpectedCalls 1 -ExpectedStatus 1
Invoke-Scenario -Statuses @(2) -ExpectedCalls 1 -ExpectedStatus 2

Write-Output 'PowerShell retry-policy checks passed.'
