# Repository Guidelines

## Project Structure & Module Organization

`project.yml` is the XcodeGen source of truth; do not edit the generated `RemoteFiles.xcodeproj`. The iOS app lives in `RemoteFiles/`: `App` starts the app, `Core` defines provider and transfer contracts, `Models` holds persisted data, `Providers` implements FTP/FTPS, SFTP, SMB, WebDAV, and NFS, `Services` handles storage and utilities, and `UI` contains SwiftUI screens. Icons and translations are in `RemoteFiles/Resources`. The system Files integration is a separate target in `RemoteFilesFileProvider/`. Tests are in `RemoteFilesTests/` and `RemoteFilesUITests/`; `altstore.json` describes the published sideloading source.

## Build, Test, and Development Commands

Use macOS with Xcode 26 and XcodeGen. From the repository root:

```sh
brew install xcodegen
xcodegen generate
xcodebuild -resolvePackageDependencies -project RemoteFiles.xcodeproj -scheme RemoteFiles
xcrun simctl list devices available
xcodebuild -project RemoteFiles.xcodeproj -scheme RemoteFiles \
  -destination 'platform=iOS Simulator,id=<UDID>' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test
```

XcodeGen regenerates the project; `xcodebuild -resolvePackageDependencies` resolves pinned Swift packages. Choose an available iOS 26 iPhone simulator for `<UDID>`. `gh workflow run ios-ci.yml` starts the same CI checks manually. CI runs on pull requests and manual dispatch, not every push to `main`.

## Coding Style & Naming Conventions

Follow nearby Swift 5.9 code: four-space indentation, `UpperCamelCase` types, `lowerCamelCase` members, and one protocol implementation per provider file. Keep remote operations `async throws`, preserve `Sendable` boundaries, and keep observable UI state on `@MainActor`. No formatter or linter is configured; run `git diff --check` before committing. Do not turn network or filesystem errors into “item not found” with broad `try?` handling.

## Testing Guidelines

Use XCTest. Name files `<Subject>Tests.swift` and methods `test<Behavior>`. Add focused regression tests for changed behavior, especially failures, cancellation, and overwrite conflicts. Prefer fake providers or in-memory stores over live servers or the simulator Keychain. Run the relevant unit tests and the UI launch smoke test before release; no numeric coverage threshold is configured.

## Commit & Pull Request Guidelines

Recent commits use short imperative subjects such as `Fix WebDAV initial-directory probe` and `Add SideStore and LiveContainer AltSource`. PRs should explain the user-visible change, affected protocols, validation performed, and any remaining limitation; include screenshots for UI changes and link an issue when one exists. For releases, increment versions in `project.yml`, use a matching `vX.Y.Z` tag, and update `altstore.json` to the published IPA URL, size, and version. Never commit credentials or signing material.
