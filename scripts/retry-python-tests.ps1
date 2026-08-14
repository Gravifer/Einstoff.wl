function Invoke-WithPythonStartupRetries {
    param(
        [Parameter(Mandatory)] [scriptblock] $Operation,
        [int] $MaximumAttempts = 4,
        [int] $DelaySeconds = 5
    )

    $attempt = 1
    while ($true) {
        $status = & $Operation
        if ($status -eq 0) {
            return
        }
        if ($status -ne 75) {
            throw "Python test execution failed with non-retryable exit code ${status}."
        }
        if ($attempt -ge $MaximumAttempts) {
            throw "Python/ZMQ startup failed after ${MaximumAttempts} attempts."
        }

        Write-Warning "Python/ZMQ startup failed on attempt ${attempt}; retrying."
        Start-Sleep -Seconds ($attempt * $DelaySeconds)
        $attempt++
    }
}
