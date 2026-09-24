# RemoteFiles

RemoteFiles 是一款面向 iPhone 和 iPad 的多协议远程文件管理器，用于统一访问和管理不同服务器、NAS 与远程存储中的文件。

## 功能

- 支持 FTP、FTPS、SFTP、SMB、WebDAV 和 NFS。
- 浏览远程目录和文件，并查看文件大小、修改时间等信息；可按名称、修改日期、大小或类型排序，并在列表与网格（大缩略图）视图之间切换。
- 可收藏常用文件夹和文件，并在首页查看最近打开的文件，一键直达。
- iPad 支持硬件键盘快捷键（刷新、新建文件夹、搜索、返回上级、复制/剪切/粘贴、删除、切换视图）。
- 支持上传文件和文件夹、新建文件夹、重命名、递归删除非空目录、批量选择与批量删除、复制/移动/粘贴，以及当前目录搜索；上传遇到同名项目时可选择替换、保留两者或跳过。
- 支持长按文件或文件夹直接执行选择、离线保存、跨服务器复制、重命名、权限查看和删除等操作。
- 支持不同远程服务器之间复制文件和文件夹（可选择目标文件夹），跨服务器粘贴同样进入传输列表；传输任务可持久化、取消和失败重试，上传失败的文件也可在传输列表中重试。
- App 切到后台后会申请额外的执行时间继续传输，并在传输完成或失败时发送通知。
- FTP、SFTP、SMB、WebDAV、NFS 可作为分块读取源；复制到 SFTP 或 SMB 时支持流式传输，避免完整文件占用本地临时空间。
- SFTP 与 SMB 目标支持字节级断点续传；其他协议在不具备可靠随机写入能力时自动安全回退为重新传输。
- 使用系统 Quick Look 预览 PDF、图片、文档、音视频及其他受支持的文件格式。
- SFTP、SMB、WebDAV、NFS 上的常见音视频（MP4、MOV、M4A、MP3 等）可边下边播并拖动进度。
- 支持预览文件的系统分享/导出，以及将远程文件保持离线。
- Offline 文件可继续预览、编辑文本/代码并保留语法高亮、系统分享、导出、复制到远程服务器；离线压缩包可浏览并解压到 Offline。
- 图片和 PDF 支持按需生成并缓存缩略图。
- 内置文本与代码编辑器，支持语法高亮、行号和远程文件保存；保存时保留原文件编码（UTF-8/UTF-8 BOM/UTF-16/GBK·GB18030）与 Unix 权限，先上传临时文件再替换，避免断线导致文件被截断；离开编辑器前提示未保存的更改。
- 无扩展名文本文件会通过内容检测自动按文本打开；常见二进制签名和二进制内容不会误进文本编辑器。
- 支持 Swift、C、C++、Python、JavaScript、TypeScript、TSX、HTML、CSS、JSON、YAML、TOML、Go、Rust、Java、PHP、SQL、Markdown、Shell 等常见语言和格式。
- 编辑远程文件时检测服务器端文件变化，避免意外覆盖其他修改。
- 支持 ZIP、7z、RAR/RAR5、TAR、tar.gz、tar.bz2、tar.xz、GZip、BZip2 和 XZ 的浏览或解压；压缩包以树状目录展示，可搜索并单独预览其中的文件；顶层包含多个项目时，解压前可选择解压到以压缩包命名的文件夹。
- 登录凭据保存在系统 Keychain 中。
- 可开启 App 锁，使用面容 ID、触控 ID 或设备密码解锁，并可设置离开后多久需要重新解锁；锁定期间传输继续进行。
- 新建连接时可自动发现局域网内的 SMB、SFTP、WebDAV、FTP 和 NFS 服务器。
- SMB 连接可直接从服务器列出共享文件夹并选择，无需事先知道共享名称。
- SFTP 支持密码以及 Ed25519、RSA、ECDSA（P-256/P-384/P-521）私钥认证，支持 OpenSSH 与 PEM 格式，可保存私钥 passphrase；连接空闲时自动保活，断线后自动重连。
- SFTP 与 NFS 支持查看和修改 Unix 权限；FTP/FTPS 在服务器支持 `SITE CHMOD` 时自动启用 Unix 权限查看和修改。
- SMB 支持读取 Windows Security Descriptor，查看 Owner、Group 与 DACL 访问控制条目。
- SFTP 支持查看 Unix 文件权限，并通过八进制模式修改文件或目录权限。
- SFTP 首次连接会记录 SSH Host Key，后续密钥发生变化时阻止连接。
- WebDAV 与 FTPS 可关闭证书验证以连接使用自签名证书的 NAS；WebDAV 会记住首次信任的证书，证书变化时阻止连接。WebDAV 支持 Basic、Digest 与 NTLM 认证。
- 可直接打开 SFTP/FTP/NFS 中指向文件夹的符号链接。
- 内置连接诊断，可检查网络连通、协议认证、目录访问和服务器能力。
- 可通过系统“文件”App 的 File Provider 集成访问已配置的远程连接，并支持浏览、下载、新建、修改、移动和删除；SFTP/SMB/WebDAV 连接在请求间复用，App 内的修改会通知“文件”App 刷新。
- 针对 iPhone 和 iPad 提供原生 SwiftUI 文件管理界面。
- 兼容 iOS 26 / iPadOS 26。

## SideStore / LiveContainer 订阅源

在 SideStore 或支持 AltSource 的 LiveContainer 中添加以下源地址：

```text
https://raw.githubusercontent.com/oexi/RemoteFiles/main/altstore.json
```

也可以使用对应应用的 URL Scheme：

```text
sidestore://source?url=https%3A%2F%2Fraw.githubusercontent.com%2Foexi%2FRemoteFiles%2Fmain%2Faltstore.json
livecontainer://sources?url=https%3A%2F%2Fraw.githubusercontent.com%2Foexi%2FRemoteFiles%2Fmain%2Faltstore.json
```

源中提供的 IPA 未签名。SideStore 会在安装时签名；LiveContainer 则依所用的签名或 JIT 模式运行。若要作为普通 App 直接安装，需要先重签。LiveContainer 不会将访客应用的 File Provider 扩展注册到系统“文件”App；需要该功能时请独立安装 RemoteFiles。
