# Stop the otel-collector service if it's running.
# Note: This assumes you've set it up as a service named "otel-collector".
$Service = Get-Service -Name "otel-collector" -ErrorAction SilentlyContinue
if ($Service) {
    Stop-Service -Name "otel-collector"
    # If you used NSSM or another tool to register otel-collector as a service, you might need to unregister it.
    # For NSSM:
    # & 'C:\path\to\nssm.exe' remove otel-collector confirm
}

# Remove otel-collector files
Remove-Item -Path "C:\Program Files\otelcol-contrib" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "C:\Program Files\otel-config.yaml" -ErrorAction SilentlyContinue

Write-Host "otel-collector uninstalled successfully!"

