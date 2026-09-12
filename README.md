# RemoteFiles

RemoteFiles 是一款面向 iPhone 和 iPad 的多协议远程文件管理器，用于统一访问和管理不同服务器、NAS 与远程存储中的文件。

## 功能

- 支持 FTP、FTPS、SFTP、SMB、WebDAV 和 NFS。
- 浏览远程目录和文件，并查看文件大小、修改时间等信息。
- 支持上传文件和文件夹、新建文件夹、重命名、删除以及当前目录搜索。
- 支持不同远程服务器之间复制文件，并通过传输列表查看任务状态；传输任务可持久化、取消和失败重试。
- FTP、SFTP、SMB、NFS 作为源并复制到 SFTP 时支持分块流式传输，避免完整文件占用本地临时空间。
- 使用系统 Quick Look 预览 PDF、图片、文档、音视频及其他受支持的文件格式。
- 支持预览文件的系统分享/导出，以及将远程文件保持离线。
- 图片和 PDF 支持按需生成并缓存缩略图。
- 内置文本与代码编辑器，支持语法高亮、行号和远程文件保存。
- 支持 Swift、C、C++、Python、JavaScript、TypeScript、TSX、HTML、CSS、JSON、YAML、TOML、Go、Rust、Java、PHP、SQL、Markdown、Shell 等常见语言和格式。
- 编辑远程文件时检测服务器端文件变化，避免意外覆盖其他修改。
- 支持 ZIP、7z、RAR/RAR5、TAR、tar.gz、tar.bz2、tar.xz、GZip、BZip2 和 XZ 的浏览或解压。
- 登录凭据保存在系统 Keychain 中。
- SFTP 支持密码以及 OpenSSH Ed25519/RSA 私钥认证，可保存私钥 passphrase。
- SFTP 首次连接会记录 SSH Host Key，后续密钥发生变化时阻止连接。
- 内置连接诊断，可检查网络连通、协议认证、目录访问和服务器能力。
- 针对 iPhone 和 iPad 提供原生 SwiftUI 文件管理界面。
- 兼容 iOS 26 / iPadOS 26。
