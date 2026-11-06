# Windows ARM64 downstream build

This fork adds a native Windows ARM64 build, with a downstream patch to the native Windows Hello integration.

## What is native

The release workflow runs on GitHub's `windows-11-arm` runner and produces an ARM64 `jpackage` application image with an ARM64 JDK, JVM, JavaFX runtime, launcher, Cryptomator Windows integrations, and WinFsp interface.

The workflow checks the PE machine type of the launchers and key runtime DLLs and then launches Cryptomator for 20 seconds on the ARM64 runner before publishing the release.

## Why the release is a ZIP, not an MSI

OpenJDK's `jpackage` still lacks reliable native Windows ARM64 MSI generation. An x64 installer can carry an ARM64 application, but that is not a fully native package and has caused installation failures in Cryptomator's earlier ARM64 experiments. The portable ZIP avoids that installer layer while keeping the application and runtime native.

## Install and run

1. Download the `windows-arm64` ZIP and its SHA-256 file from this fork's latest ARM64 prerelease.
2. Verify the checksum, then extract the ZIP to a directory you control.
3. Optionally install [WinFsp 2.1 or newer](https://github.com/winfsp/winfsp/releases) for the WinFsp volume type.
4. Run `Cryptomator.exe` from the extracted `Cryptomator` directory.

The downstream binary is unsigned, so Windows may show a SmartScreen warning. Windows Hello and the standard Windows Data Protection keychain are available. The ARM64 workflow builds a downstream patch that executes Hello availability and password operations on a separate MTA worker. It also validates credential-open results before use. Existing Hello key identifiers and saved-password encryption are unchanged. Interactive PIN/biometric authentication requires validation on a real enrolled device. Automatic in-app updates are disabled because the official Windows updater currently points to x64 packages.

## Build and upstream synchronization

- `.github/workflows/windows-arm64-release.yml` builds, validates, packages, and publishes the ARM64 prerelease entirely on GitHub Actions.
- `dist/win/arm64/windows-hello-threading.patch` corrects blocking WinRT operations on STA threads, initializes COM before cryptographic API use, and validates credential-open results. The patch is applied and compiled only inside the ARM64 workflow.
- Native and JNI probes check pending asynchronous operations, exception propagation, malformed inputs, and the real availability API. The app smoke test uses temporary settings with Windows Hello selected. These checks cannot exercise a biometric/PIN prompt on an unenrolled runner.
- `.github/workflows/sync-upstream.yml` merges `cryptomator/develop` into this fork's `develop` branch every day and can also be run manually.
- No pull request is opened against the upstream Cryptomator repository.
