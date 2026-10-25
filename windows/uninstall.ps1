# Stop the otel-collector service if it's running.
# Note: This assumes you've set it up as a service named "otel-collector".
$Service = Get-Service -Name "otel-collector" -ErrorAction SilentlyContinue
if ($Service) {
    Stop-Service -Name "otel-collector" -ErrorAction Stop
    # Unregister the service, otherwise it lingers pointing at a deleted binary.
    sc.exe delete "otel-collector" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: sc.exe delete failed (exit code $LASTEXITCODE); otel-collector was not uninstalled."
        exit 1
    }
}

# Remove otel-collector files
Remove-Item -Path "C:\otel-collector" -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "otel-collector uninstalled successfully!"

