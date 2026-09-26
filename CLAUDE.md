# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

RemoteFiles is an iPhone/iPad SwiftUI file manager for FTP/FTPS, SFTP, SMB, WebDAV and NFS, with a File Provider extension for the system Files app. `AGENTS.md` holds the contributor rules (style, commit and PR conventions); this file adds the build workflow and the architecture you need to read several files to understand.

## Build and test

`project.yml` (XcodeGen) is the source of truth. `RemoteFiles.xcodeproj` is generated and git-ignored, so never edit it. Toolchain: macOS, Xcode 26, Swift 5.9 language mode, iOS 17 deployment target.

```sh
xcodegen generate
xcodebuild -resolvePackageDependencies -project RemoteFiles.xcodeproj -scheme RemoteFiles
xcodebuild -project RemoteFiles.xcodeproj -scheme RemoteFiles \
  -destination 'platform=iOS Simulator,id=<UDID>' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  -parallel-testing-enabled NO -only-testing:RemoteFilesTests test
# Single test: -only-testing:RemoteFilesTests/TransferEngineTests/testSomething
# UI smoke test: -only-testing:RemoteFilesUITests/LaunchTests/testLaunches
```

- **No local Swift toolchain (e.g. Linux sessions):** CI is the compiler. It builds, checks the extension's Info.plist, runs unit tests and the launch test.
  - CI runs on pull requests and manual dispatch only, not on pushes (to `main` or any branch).
  - A branch that will get a PR: open the PR (a draft is fine) and let its `pull_request` run be the check; watch it with `gh pr checks --watch`. Do not also `gh workflow run` it, or CI runs twice.
  - `gh workflow run ci.yml --ref <branch>` is only for branches without a PR. Runs share one concurrency slot per branch, so a newer run (PR or dispatch) cancels the older one.
  - Logs come back as the `ci-logs` artifact: `gh run download <id> -n ci-logs`, then grep `build.log` for `error:` and `test.log` (unit tests and launch test) for `Test Suite`.
- **Parallel testing must stay off.** Several tests use `URLProtocol` mocks with static state.
- **No linter or formatter.** Run `git diff --check` before committing.
- **Long SwiftUI modifier chains:** they can hit "unable to type-check this expression in reasonable time". Split the view into computed sub-views, as `BrowserView` does with `browserBase` / `browserWithPrompts` / `body`.

## Release

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`.
2. Merge to `main`.
3. Push the tag `vX.Y.Z`. It must equal `MARKETING_VERSION`, or `release.yml` fails.

The tag workflow then builds an unsigned IPA, publishes the GitHub Release, and commits the updated `altstore.json` (SideStore/LiveContainer source) to `main` on its own. `workflow_dispatch` on a branch only produces the IPA artifact.

## Architecture

### Targets and shared code

The app target compiles all of `RemoteFiles/`. The `RemoteFilesFileProvider` extension target compiles only its own folder plus these shared sources:

- `RemoteFiles/Core` (except `TransferEngine.swift`)
- `RemoteFiles/Models`
- `RemoteFiles/Providers`
- a few files explicitly listed in `project.yml` (`AppVersion`, `CredentialVault`, `SSHHostKeyStore`, `WindowsSecurityDescriptorParser`)

Consequences:
- Code in Core, Models or Providers must be extension-safe (`APPLICATION_EXTENSION_API_ONLY`): no `UIApplication` and no app-only services.
- A Services file the extension needs must be added to the extension's `sources` in `project.yml`.
- App and extension share the app group `group.com.oexi.RemoteFiles` (profiles, identity and snapshot state) and the keychain access group `…com.oexi.RemoteFiles.shared` (credentials, SSH host keys, TLS pins).

### Provider layer

- **Core protocol:** `RemoteFileProvider` (`Core/RemoteFileProvider.swift`). All operations are `async throws`, and paths are absolute, server-side, normalized with `RemotePath`.
- **Opt-in protocols:** extra abilities are separate protocols, detected with `as?`:
  - `RemoteChunkReadableProvider` / `RemoteChunkWritableProvider` (range I/O and streaming sessions, used for resumable transfers)
  - `RemoteChunkReadSupportProbing`
  - `RemoteSymbolicLinkInspecting`

  `ProviderCapabilities` separately advertises what the UI may offer.
- **Not-found contract:** a provider must map its native "missing item" error to `RemoteProviderError.notFound`. Callers branch on `RemoteProviderError.isNotFound(_:)` for existence checks (paste-name probing, resume, safe replace). Never turn other errors into "not found".
- **Construction:** `ProviderFactory.make(for:credential:)` builds a provider from a `ConnectionProfile`, loading the credential from `CredentialVault` if none is passed.
- **Connection lifecycle:** differs per protocol.
  - SFTP (Citadel) and SMB (forked SMBClient) connect lazily. Connection state sits behind an `NSLock`, and concurrent callers share one in-flight connect task. A dropped session is replaced on the next call.
  - SFTP, SMB and WebDAV close their connection in `deinit`. Whoever holds the provider keeps the connection alive, so don't call `disconnect()` on a provider something else may still be using.
  - WebDAV recreates its `URLSession` after `disconnect()`. `WebDAVSessionDelegate` handles Digest/NTLM auth and TLS pinning.
- **Certificates:** when `verifyTLS` is off, WebDAV pins the first certificate it sees (`Core/TLSCertificateTrust.swift`), while FTPS accepts any certificate (a FilesProvider limitation).
- **ECDSA keys:** Citadel only parses Ed25519/RSA OpenSSH keys. ECDSA keys and their bcrypt passphrase encryption are handled by `SSHPrivateKeyLoader` and `BCryptPBKDF` (the Blowfish tables in `BCryptPBKDF+Constants.swift` are generated digits of pi).

### Transfers (`Core/TransferEngine.swift`, app only)

- **State:** a `@MainActor` engine that persists `TransferRecord`s to `transfers.json`. Record kinds: `serverToServer`, `upload`, `download`.
- **Execution ownership:** each run holds a `TransferExecutionToken`. Guard state mutations with `update(_:token:)`, so a cancelled or retried task can't overwrite a newer run.
- **Resumable copies:**
  - Data streams into a hidden sibling file `.remotefiles-<record-uuid>.partial`, which is then renamed into place.
  - `commitPending` covers the rename window, so a relaunch can reconcile an interrupted commit.
  - `TransferResumePolicy` decides between resume and restart from the source revision (ETag, or mtime plus size).
- **Connections:** `perform` disconnects its destination (and its source, if `disconnectSource`). Folder copies (`copyItems`) therefore build a fresh provider pair per file via the injected `makeProvider`, and run files one at a time.
- **Upload retry:** a failed browser upload is moved to `RetainedUploads/<id>/` so it can be retried.
- **Background:** `App/TransferBackgroundActivity` watches `records` to hold a UIKit background task and post notifications.

### File Provider extension

- **Domains:** one File Provider domain per connection profile (domain identifier = profile UUID), kept in sync by `Services/FileProviderDomainManager`. Profiles are mirrored into the app group with `FileProviderProfileStore`, because the extension can't read the app's `ConnectionStore`.
- **Item identifiers:** `path:<base64url(path)>`. `FileProviderIdentityStore` persists overrides (`item:<uuid>`) so items moved by the extension keep their identity.
  - The app must only use the read-only `knownIdentifier(for:codec:)`. Writing identity state from the app would race with the extension.
- **Change tracking:** `FileProviderSnapshotStore` saves per-container fingerprints; `enumerateChanges` diffs against them.
- **Connections:** `FileProviderConnectionPool` shares SFTP/SMB/WebDAV providers across requests (60 s idle eviction, rebuilt when the credential changes). FTP/NFS get a new connection per request.
- **Errors:** everything returned to the Files app goes through `FileProviderErrorMapping.map`.
- **Special containers:** `.workingSet` and `.trashContainer` use `FileProviderEmptyEnumerator`.

### UI

- **Environment objects:** `RemoteFilesApp` provides `ConnectionStore`, `TransferEngine`, `OfflineStore` and `FileOperationClipboard`.
- **Browser:** `BrowserViewModel` owns one provider per browser screen.
  - A `listGeneration` counter discards directory listings that finished after the user moved on.
  - Changes made in the app call `FileProviderDomainManager.signalChange` so the Files app refreshes.
- **Editors:** `RemoteEditorView` and `LocalTextEditorView` keep the file's original encoding (`TextEncoding`, which includes GB18030). Remote saves go through `RemoteFileOperations.replaceFile` (staged upload plus rename).
- **Media preview:** all audio and video plays in libmpv (MPVKit) via `MPVPlayerView`; there is no AVFoundation player. Subtitles are off; the preview is kept simple.
  - `MPVPlayer` registers a `remotefiles://` stream protocol. Its callbacks read through `RemoteByteStream` (blocking range reads on mpv's demux thread), and read-ahead stays in memory.
  - FTP/FTPS never stream, because every range needs a new connection. Those files are downloaded into `CacheManager` first, then played locally.
  - Audio keeps playing in the background (`UIBackgroundModes: audio` in `RemoteFiles/Info.plist`). In the background video is switched off (`vid=no`), and `MPVPlayer` publishes Now Playing info and handles remote commands and audio-session interruptions.
  - MPVKit's MoltenVK context reads the layer size (bounds × contentsScale, not `drawableSize`) only when video starts, and ignores later resizes such as rotation. So video starts disabled (`vid=no`). Once the track list gives the video dimensions, the layer's bounds are set to the video's pixel size and never change again. Fitting the layer to the screen then uses only a scale transform (`MPVPlayer.layout`).
- **Localization:** UI strings live in `Resources/{en,zh-Hans,zh-Hant}.lproj/Localizable.strings`. Add new keys to all three files; zh-Hant uses 資料夾 / 檔案 / 伺服器 terminology.

## Tests

- **XCTest only:** unit tests go in `RemoteFilesTests`, named `<Subject>Tests.swift` / `test<Behavior>`.
- **No live servers:** use fakes and injection points instead:
  - `MemoryRemoteProvider` (an in-memory file system; several instances can share one `Storage`; failures injected per operation string such as `"upload:/a.txt"`)
  - `TransferEngine(fileURL:makeProvider:)`
  - `BrowserViewModel(profile:makeProvider:)`
  - `WebDAVProvider(profile:credential:session:)` with a custom `URLProtocol`
- **Keychain and File Provider in tests:** `ConnectionStore` and `FileProviderDomainManager` skip File Provider domain registration and signalling under XCTest. Avoid tests that depend on the real keychain.
