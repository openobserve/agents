# Define the version
$version = "7.4.0"

# Determine OS architecture
if ([System.Environment]::Is64BitOperatingSystem) {
    $architecture = "x64"
} else {
    $architecture = "x86"
}


# PowerShell 7.3 download URL
$url = "https://github.com/PowerShell/PowerShell/releases/download/v$version/PowerShell-$version-win-$architecture.msi"

# Download destination
$dest = "$env:TEMP\PowerShell-$version-win-$architecture.msi"

# Download the installer
Invoke-WebRequest -Uri $url -OutFile $dest

# Install PowerShell 7.3
Start-Process msiexec.exe -Wait -ArgumentList "/i $dest /quiet /norestart"

# Remove the installer
Remove-Item -Path $dest

