# Windows builds for ARM64 and x64

This fork publishes regular, unofficial Windows releases built from upstream's development branch. The application, installer display name, release title, tag and downloads keep the exact version from the revision's `pom.xml`, including `-SNAPSHOT` when present. Only numeric Windows package metadata uses its major.minor.patch part. A regular fork release is not an official stable upstream release. Older preview downloads remain available.

## Install

1. In Windows Settings → System → About, check **System type**. Download the **arm64.msi** for an ARM-based processor or the **x64.msi** for Intel/AMD. A portable ZIP is also available for each architecture.
2. Verify the download against its accompanying SHA-256 file. The installers are unsigned. Exit other Cryptomator processes before installing or switching versions.
3. Double-click the MSI for the interactive wizard (license, destination, shortcut, installation and maintenance). On ARM64, the entry in Installed apps and the Start shortcut are both **Cryptomator**, with the upstream icon. This unsigned downstream MSI replaces compatible official MSI installations in **C:\Program Files\Cryptomator**, using the official MSI family and vendor registry path. It does not remove separate older fork installations. The x64 installer and its **Cryptomator (x64)** shortcut remain separate. Existing settings and vaults are used. Keep your normal vault password.
4. WinFsp is optional and not bundled. For the WinFsp volume type use [WinFsp 2.1 or newer](https://github.com/winfsp/winfsp/releases). In-app update checks are disabled for these downstream packages; download updates here.

## Build and validation

The Windows installers workflow builds on separate native ARM64 and x64 runners. WiX builds separate architecture-tagged MSIs. CI checks the Windows Installer platform, the launcher, JVM, JavaFX and Windows Hello integration; installs each MSI; compares its installed files to the checked app image; starts the installed application with Hello selected in temporary settings; and uninstalls it. Both must pass before the workflow publishes the MSIs, portable ZIPs, checksums and corresponding modified ARM64 runtime source. No installer downloads components when run.

The Windows Hello integration patch runs WinRT calls on an MTA worker, retains the MTA while its cached factories are in use, and validates credential-open results. Both architectures compile and test that integration. The ARM64 runtime workflow builds pinned OpenJDK 27.0.1.0.3 with the first-chance cryptography exception fix. The installer workflow checks the source workflow and patch against that successful build before consuming it. x64 uses a native Temurin JDK. Both retain upstream's certificate and font packaging steps. CI checks Hello availability and failure handling, not interactive biometric/PIN unlock on an enrolled device.

The daily sync workflow merges upstream develop into this fork without opening an upstream PR. To rebuild a changed ARM64 runtime, dispatch the Windows ARM64 Java 27 runtime workflow on develop, then supply its successful run ID to the Windows installers workflow. There is no version override. If the upstream version already has a tag, publication stops instead of inventing a version or overwriting a release.
