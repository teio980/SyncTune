# SyncTune

SyncTune 是 Windows 和 Android 上的手动音乐双向同步工具。设置一个本地音乐文件夹和一个 WebDAV 文件夹；同步按相对路径与文件名匹配，并用 SHA-256 检查内容。

## 使用

1. 安装 Windows 桌面版，或按设备架构安装 Android APK。
2. 打开“设置”，选择本地文件夹，填写 HTTPS WebDAV 地址、远程目录和用户名，然后保存密码。
3. 回到主页，点击“开始同步”。Android 需要通知权限，才能在应用切到后台或锁屏时继续当前任务。

只同步 `.mp3`、`.flac`、`.wav`、`.m4a`、`.aac`、`.ogg` 和 `.opus`。跳过符号链接、Windows 重解析点、非音乐文件，以及 `.synctune`、`.synctune-local`、`.synctune-local-v2` 目录；不上传空目录。

## 同步规则

- 首次同步合并双方已有的歌曲，不推断删除。同路径内容不同时，云端版本留在原路径，本地版本另存为带 SHA-256 的冲突副本。
- 之后按上次成功记录比较。只有一边修改就传播修改；一边删除就删除另一边，包括“删除对修改”。双方改成不同内容时，原路径保留云端版本，本地版本另存为冲突副本。重命名按删除旧路径、新增新路径处理。
- 扫描、权限或 WebDAV 列表不完整时停止本轮，不传播删除。每个文件单独确认和保存；失败或取消时，已完成的文件可能保留，下次手动启动会核对未完成操作再继续。
- 有未变化的强 ETag 时可复用已确认的云端哈希。没有强 ETag 时，每轮可能读取大量云端歌曲；写入前复查并在写入后校验，但这不提供原子并发保护。建议设备错峰同步。强 ETag 条件写遇到 HTTP 412 会停止并要求重新扫描。

更换本地文件夹、服务器地址、远程目录或账号会建立新基线；仍有待恢复操作时不能更换。新版使用新的 v2 数据库，不迁移旧设置或同步记录。已有音乐以及旧恢复目录不会被自动清理。密码存放在系统凭据存储中，不写入数据库。

## 开发与发布

```powershell
flutter pub get
flutter run -d windows
flutter run -d <android-device>
flutter build apk --release --split-per-abi
flutter build windows --release
```

Android 发布时默认提供 arm64 APK，其他架构分别提供。Windows 发布为包含完整 Release 目录的 ZIP。当前代码变更没有在本轮进行构建、Android 真机或外部 WebDAV 服务验收；需要在目标设备和服务器上验证。

应用只保留一个同步主页和一个设置页；界面提供简体中文和英文，主题跟随系统。技术依赖以 `pubspec.yaml` 为准：Flutter、SQLite (`sqlite3`)、Dio、XML 和 SHA-256。

---

## English

SyncTune manually synchronizes music between one local folder and one WebDAV folder. Choose both locations in **Settings**, then press **Start sync** when needed. The first run merges existing songs; later runs propagate edits and deletions. Different edits are kept as separate files. Android requires notification permission for background sync. Passwords use the system credential store, and older settings are not migrated. This rebuild has not been verified on a physical Android device or an external WebDAV server.
