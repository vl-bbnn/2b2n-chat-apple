#!/bin/bash

set -euo pipefail

if [[ -n "${BUILD_CERTIFICATE_BASE64:-}" ]]; then
    if [[ -z "${P12_PASSWORD:-}" || -z "${KEYCHAIN_PASSWORD:-}" ]]; then
        echo "P12_PASSWORD and KEYCHAIN_PASSWORD are required when BUILD_CERTIFICATE_BASE64 is set" >&2
        exit 1
    fi

    certificate_path="$RUNNER_TEMP/build_certificate.p12"
    keychain_path="$RUNNER_TEMP/app-signing.keychain-db"

    printf '%s' "$BUILD_CERTIFICATE_BASE64" | base64 -D > "$certificate_path"

    security create-keychain -p "$KEYCHAIN_PASSWORD" "$keychain_path"
    security set-keychain-settings -lut 21600 "$keychain_path"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$keychain_path"
    security import "$certificate_path" -P "$P12_PASSWORD" -A -t cert -f pkcs12 -k "$keychain_path"
    security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" "$keychain_path"
    security default-keychain -d user -s "$keychain_path"
    security list-keychain -d user -s "$keychain_path"

    identities_output="$(security find-identity -v -p codesigning "$keychain_path" || true)"
    printf '%s\n' "$identities_output"
    if [[ "$identities_output" == *"0 valid identities found"* ]]; then
        echo "No valid code signing identities were imported from BUILD_CERTIFICATE_BASE64" >&2
        exit 1
    fi
else
    echo "BUILD_CERTIFICATE_BASE64 is not set, relying on Xcode automatic/cloud signing"
fi

if [[ -n "${APPLE_PROVISIONING_PROFILES_ARCHIVE_BASE64:-}" ]]; then
    archive_path="$RUNNER_TEMP/apple-profiles.tar.gz"
    profile_dir="$HOME/Library/MobileDevice/Provisioning Profiles"

    mkdir -p "$profile_dir"
    printf '%s' "$APPLE_PROVISIONING_PROFILES_ARCHIVE_BASE64" | base64 -D > "$archive_path"
    tar -xzf "$archive_path" -C "$profile_dir"
    find "$profile_dir" -maxdepth 1 \( -name '*.mobileprovision' -o -name '*.provisionprofile' \) -print
else
    echo "APPLE_PROVISIONING_PROFILES_ARCHIVE_BASE64 is not set, relying on Xcode automatic/cloud signing"
fi
