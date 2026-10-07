# SyncTune 本轮交付

## 使用

1. 在 Windows 安装已签名的 `SyncTune-Windows-1.0.0.22.msix`；Android 安装 `SyncTune-Android-1.0.0+3.apk`。Android 新包与 +2 的签名一致，可覆盖安装。
2. 首次打开后分别选择音乐根目录，确认授权仍有效。
3. 在设置中填写 HTTPS WebDAV 地址、账号和密码，先执行连接检查，再从同步页手动同步。
4. 同步前保持根目录可写；中断后重新打开应用会先检查未完成操作并恢复可恢复备份。

## 本轮限制

Android +3 修复同步时仍显示“准备就绪”的状态矛盾，显示扫描、校验、上传、下载、最终复核等实际阶段，并显示当前文件、已处理数量、文件字节进度和耗时。失败会保留最后的阶段和文件。文件处理进度与同步操作数量分别标注；文件字节处理完成后仍须通过最终复核才会显示同步完成。

Android 文件读取改为按根目录和路径绑定的连续流，避免每 64 KB 重新查找、打开文件并跳过已读内容。EOF、取消读取、撤销授权和 Activity 销毁会关闭读取句柄。Windows 安装包仍为之前的构建，不包含本次界面修复。

- 本轮包只做构建与静态验证，未安装、启动、选择目录或连接用户 WebDAV；请用户自行完成功能测试。
- 远端同步要求服务支持强 ETag 与 `If-Match` 条件请求。
- 本地能力是“哈希核对、根目录 `.synctune-local` 备份、提交后校验和可恢复删除”，不承诺通用 SAF/AppContainer 原子 CAS。冲突或未知内容会保留并要求重新扫描。
- Android APK 使用当前开发签名配置，适合内部测试，不是商店发布签名。
- Windows 包保持 `SyncTune.Probe` 的既有 PFN/发布者，使用已信任的 `CN=SyncTune Development` 证书签名。

## 校验

- Android +3 SHA-256：`34A7AAD936BD7CBA25DA4F516988DA073A441C399D6C0391B65AF02495A9CBE7`
- Windows SHA-256：`5FF234ADC0FE2E287E4018FEDDDF5E7721E9767EB008E6EE5DEDAACD1B777888`
- Windows 构建日志：`build/gate/windows-sync-recovery-release-final.log`
- Android +3 构建日志：`build/sync-fix-apk.log`
