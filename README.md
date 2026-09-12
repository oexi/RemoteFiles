# RemoteFiles

RemoteFiles 是一款面向 iPhone 和 iPad 的多协议远程文件管理器，用于统一访问和管理不同服务器、NAS 与远程存储中的文件。

## 功能

- 支持 FTP、FTPS、SFTP、SMB、WebDAV 和 NFS。
- 浏览远程目录和文件，并查看文件大小、修改时间等信息。
- 支持上传文件和文件夹、新建文件夹、重命名、递归删除非空目录、批量选择与批量删除、复制/移动/粘贴，以及当前目录搜索。
- 支持长按文件或文件夹直接执行选择、离线保存、跨服务器复制、重命名、权限查看和删除等操作。
- 支持不同远程服务器之间复制文件，并通过传输列表查看任务状态；传输任务可持久化、取消和失败重试。
- FTP、SFTP、SMB、WebDAV、NFS 可作为分块读取源；复制到 SFTP 或 SMB 时支持流式传输，避免完整文件占用本地临时空间。
- SFTP 与 SMB 目标支持字节级断点续传；其他协议在不具备可靠随机写入能力时自动安全回退为重新传输。
- 使用系统 Quick Look 预览 PDF、图片、文档、音视频及其他受支持的文件格式。
- 支持预览文件的系统分享/导出，以及将远程文件保持离线。
- Offline 文件可继续预览、编辑文本/代码并保留语法高亮、系统分享、导出、复制到远程服务器；离线压缩包可浏览并解压到 Offline。
- 图片和 PDF 支持按需生成并缓存缩略图。
- 内置文本与代码编辑器，支持语法高亮、行号和远程文件保存。
- 无扩展名文本文件会通过内容检测自动按文本打开；常见二进制签名和二进制内容不会误进文本编辑器。
- 支持 Swift、C、C++、Python、JavaScript、TypeScript、TSX、HTML、CSS、JSON、YAML、TOML、Go、Rust、Java、PHP、SQL、Markdown、Shell 等常见语言和格式。
- 编辑远程文件时检测服务器端文件变化，避免意外覆盖其他修改。
- 支持 ZIP、7z、RAR/RAR5、TAR、tar.gz、tar.bz2、tar.xz、GZip、BZip2 和 XZ 的浏览或解压。
- 登录凭据保存在系统 Keychain 中。
- SFTP 支持密码以及 OpenSSH Ed25519/RSA 私钥认证，可保存私钥 passphrase。
- SFTP 与 NFS 支持查看和修改 Unix 权限；FTP/FTPS 在服务器支持 `SITE CHMOD` 时自动启用 Unix 权限查看和修改。
- SMB 支持读取 Windows Security Descriptor，查看 Owner、Group 与 DACL 访问控制条目。
- SFTP 支持查看 Unix 文件权限，并通过八进制模式修改文件或目录权限。
- SFTP 首次连接会记录 SSH Host Key，后续密钥发生变化时阻止连接。
- 内置连接诊断，可检查网络连通、协议认证、目录访问和服务器能力。
- 可通过系统“文件”App 的 File Provider 集成访问已配置的远程连接，并支持浏览、下载、新建、修改、移动和删除。
- 针对 iPhone 和 iPad 提供原生 SwiftUI 文件管理界面。
- 兼容 iOS 26 / iPadOS 26。
