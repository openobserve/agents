# Stop the otel-collector service if it's running.
# Note: This assumes you've set it up as a service named "otel-collector".
$Service = Get-Service -Name "otel-collector" -ErrorAction SilentlyContinue
if ($Service) {
    Stop-Service -Name "otel-collector"
}

# Remove otel-collector files
Remove-Item -Path "C:\otel-collector" -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "otel-collector uninstalled successfully!"

