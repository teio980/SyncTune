# SyncTune

SyncTune 是 Windows 和 Android 上的手动音乐双向同步工具。选择一个本地音乐文件夹，在设置中填写完整的 HTTPS WebDAV 目标地址，然后按需开始同步。地址示例：`https://example.com/dav/Music/synctune`。不再单独填写远程目录；已有设置会显示原来的完整有效地址。

## 使用

1. 打开“设置”，选择本地音乐文件夹并填写完整 WebDAV 地址、用户名和密码。
2. 可先点“测试连接”。此操作只对目标地址发送只读 `PROPFIND`，不会创建目录、写测试文件或修改同步记录。
3. “音乐”页显示所选本地文件夹中的音乐。选择歌曲并确认后，只会删除所选本地音乐文件；已登记歌曲的删除会在下次同步传播到 WebDAV。尚未登记的云端独有歌曲可能在首次同步时重新下载。
4. 在“同步”页按“开始同步”。Android 需要允许通知，当前任务才能在切到后台或锁屏后继续。

密码使用系统凭据存储，不写入 SQLite。密码框默认隐藏；已保存的密码会显示状态，点击眼睛图标可查看，保存时留空会保留当前账号的密码。

## 同步规则

- 只同步 `.mp3`、`.flac`、`.wav`、`.m4a`、`.aac`、`.ogg` 和 `.opus`，扩展名不区分大小写。跳过符号链接、Windows 重解析点、非音乐文件以及 `.synctune`、`.synctune-local`、`.synctune-local-v2` 目录；不上传空目录。
- 首次同步合并双方已有的歌曲，不推断删除。同路径内容不同时，云端版本留在原路径，本地版本另存为带 SHA-256 的冲突副本。
- 后续按上次成功记录比较。一边修改会传播修改；一边删除会删除另一边，包括“删除对修改”。双方改成不同内容时保留两个版本。重命名按删除旧路径和新增新路径处理。
- 扫描、权限或 WebDAV 列表不完整时停止本轮，不传播删除。每个文件单独确认；失败或取消时，已经完成的文件可能保留，下次手动启动会先核对未完成操作。
- 未变化的强 ETag 可复用已确认的云端哈希。没有强 ETag 时，每轮可能读取大量云端歌曲；写入前复查并在写入后校验，但这不提供原子并发保护。建议设备错峰同步。强 ETag 条件写遇到 HTTP 412 会停止并要求重新扫描。
- 更换本地文件夹、WebDAV 目标地址或账号会建立新基线；仍有待恢复操作时不能更换。旧恢复目录不会被自动清理。

## 开发

```powershell
flutter pub get
flutter run -d windows
flutter run -d <android-device>
flutter build windows --release
```

Android 发布可按架构分别构建：`flutter build apk --release --split-per-abi`。Windows 发布提供完整 Release 目录的 ZIP。应用提供简体中文和英文，主题跟随系统。依赖以 `pubspec.yaml` 为准。

## 本轮验证

- `flutter analyze` 通过；`flutter test` 的 24 项测试通过。
- `flutter build windows --release` 通过。
- Android 的 4 项 JVM 单测通过；Debug 与 Release 的 Flutter、Kotlin 编译任务通过。本轮没有组装 APK/AAB。
- 这些自动检查不代表设备或服务器验收。Android SAF 尚未在真机上验证，WebDAV 尚未对用户的实际服务器进行连接与同步验证。

---

## English

SyncTune manually synchronizes music between one local folder and one WebDAV target. Enter the complete HTTPS target URL in Settings; there is no separate remote-folder field. “Test connection” sends a read-only `PROPFIND`. The Music page lists local songs and deletes only the selected files after confirmation. Deleting a song already in the sync history propagates on the next sync; an unregistered cloud-only song may be downloaded during the first sync. Passwords stay in the operating system’s secure credential store; a blank password field keeps the saved password. Android background sync requires notification permission. SyncTune supports Chinese and English and follows the system theme.

Automated checks for this revision passed: 24 Flutter tests, 4 Android JVM tests, Windows Release compilation, and Android Debug/Release Flutter and Kotlin compilation. Android SAF on a physical device and connection/sync against the user’s WebDAV server remain unverified.
