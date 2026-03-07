你现在是一个高级软件架构师和全栈开发工程师。

请为我设计并部分实现一个跨平台音乐播放器，要求如下：

---

## 目标

- 本地 MP3 播放器，支持播放、暂停、跳转、播放列表、随机播放和循环。
- 扫描本地音乐文件夹（Music/Artist/Song.mp3），读取 ID3 Metadata。
- 将音乐信息存储在 SQLite 数据库中，字段包括：
    id, title, artist, album, file_path, file_hash(MD5), modified_time。
- UI 上保留“是否同步”开关，用户可以选择开启或关闭同步。
- 云端同步暂时可以不用接入，未来可扩展 Google Drive、NAS(WebDAV)。
- 系统无需中心服务器，所有逻辑在客户端完成。
- 架构必须模块化、可扩展、可维护。

---

## 模块划分

1. **player**: 音乐播放控制（播放、暂停、跳转、播放列表、随机、循环）
2. **library**: 扫描本地文件夹，读取 MP3 ID3 Metadata，存 SQLite
3. **sync**: 暂时保留开关状态记录（SharedPreferences/SQLite），未来扩展云端同步
4. **storage**: StorageAdapter 接口及未来实现（GoogleDriveAdapter / WebDAVAdapter）
5. **ui**: Home, Library, NowPlaying, SyncSettings

---

## Android 技术栈

- Kotlin + MVVM
- ExoPlayer（播放）
- WorkManager（后台同步，可暂不实现）
- SQLite（音乐库）
- 模块目录：
    app/
      src/
        main/
          java/com.example.musicplayer/
            ui/
            player/
            library/
            sync/
            storage/
          res/layout/

---

## Windows 技术栈

- Electron + React（推荐）
- 或 Python + Qt（可选）
- 模块目录：
    windows/
      src/
        main/
        renderer/
          components/
          player/
          library/
          sync/
          storage/

---

## SyncSettings UI

- 组件：
    - 开关：Enable Cloud Sync
    - 状态：Enabled / Disabled
    - 手动同步按钮（暂不实现功能）
- 未来扩展：新增云端存储只需实现 StorageAdapter

---

## 示例功能代码

1. **ID3 Metadata 读取**
2. **SQLite 写入**
3. **播放器控制（ExoPlayer）**
4. **Sync 开关状态记录**

---

## 交付物

- Android 项目结构
- Windows 项目结构
- SQLite 数据库 schema
- 模块架构图
- SyncStub 示例
- 播放器示例代码
- Metadata 读取示例代码
- SyncSettings UI 示例代码

---

## 要求

- 架构清晰，模块化，易扩展
- 保留“是否同步”开关，暂不接入云端接口
- 未来可直接接入 Google Drive / NAS/WebDAV
- 不使用任何中心服务器
- 代码示例使用 Kotlin（Android）、TypeScript/React（Windows）