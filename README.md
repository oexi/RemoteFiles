# RemoteFiles

RemoteFiles is an iPhone/iPad remote file manager built around one provider abstraction rather than protocol-specific UI.

Supported/planned protocols: FTP, FTPS, SFTP, SMB, WebDAV and NFS. The app also contains a transfer queue, cache, Keychain credentials, Quick Look preview, code editing and archive handling.

## Generate the Xcode project

The repository uses XcodeGen so the project definition stays reviewable.

```bash
brew install xcodegen
xcodegen generate
open RemoteFiles.xcodeproj
```

The DevSpace host is Linux and does not contain Swift/Xcode, so the final iOS build must be validated on macOS with Xcode.

