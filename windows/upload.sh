#!/bin/bash

# This script downloads the OpenTelemetry Collector release files from GitHub, converts the .tar.gz file to .zip file and uploads to s3.
# Uploading the file as .zip allows downloading the file and extracting it without upgrading powershell to 6 and above.
# Default version of powershell is 5.1 which does not support extracting .tar.gz files natively.

# Set your variables
OTEL_VERSION="0.90.1"  # The desired version
OS="windows"           # Operating system
ARCHS=("amd64" "386")  # Architectures
ROOT_DIR="${OTEL_VERSION}"  # Root directory for the operation

# Create the root directory
mkdir -p "${ROOT_DIR}"

# Loop over each architecture
for ARCH in "${ARCHS[@]}"; do
    ARCH_DIR="${ROOT_DIR}/${ARCH}"
    mkdir -p "${ARCH_DIR}"  # Create architecture-specific directory
    FILENAME="otelcol-contrib_${OTEL_VERSION}_${OS}_${ARCH}"

    # Form the download URL
    URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/${FILENAME}.tar.gz"

    # Download the file
    curl -L "${URL}" -o "${FILENAME}.tar.gz"

    # Extract the tar.gz file to the architecture-specific directory
    tar -xzvf "${FILENAME}.tar.gz" -C "${ARCH_DIR}"

    # Change directory to the architecture-specific directory
    pushd "${ARCH_DIR}"

    # Convert extracted files to a zip file
    zip -r "../${FILENAME}.zip" *  # Zip the contents of the directory

    # Revert back to the original directory
    popd

    # Upload the zip file to S3
    aws s3 cp "${ROOT_DIR}/${FILENAME}.zip" "s3://zinc-public-data/opentelemetry-collector-releases/"

    # Optional: Remove the local files after upload
    rm "${FILENAME}.tar.gz"
    rm -r "${ARCH_DIR}"
    rm "${ROOT_DIR}/${FILENAME}.zip"
done
