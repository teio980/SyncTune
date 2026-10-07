import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'webdav_strings.dart';

/// Translate app-owned copy at the presentation boundary. Runtime messages
/// remain stable so an active message can be translated after a language change.
class SyncTuneStrings {
  const SyncTuneStrings(this.locale);
  final Locale locale;

  static SyncTuneStrings of(BuildContext context) =>
      Localizations.of<SyncTuneStrings>(context, SyncTuneStrings) ??
      SyncTuneStrings(
        Localizations.maybeLocaleOf(context) ?? const Locale('en'),
      );

  static const delegate = _StringsDelegate();
  static const supportedLocales = [Locale('en'), Locale('zh')];

  String text(String value) {
    if (locale.languageCode != 'zh') return value;
    final translated = chinese[value] ?? webDavChinese[value];
    if (translated != null) return translated;
    if (value.contains('\n')) return value.split('\n').map(text).join('\n');
    // Preserve user-owned paths and technical details following known labels.
    for (final entry in prefixes.entries) {
      if (value.startsWith(entry.key)) {
        return '${entry.value}${value.substring(entry.key.length)}';
      }
    }
    return value;
  }

  static const prefixes = {
    'Expected bytes: ': '应接收字节数：',
    'Received bytes: ': '已接收字节数：',
    'Files processed: ': '已处理文件：',
    'Operations completed: ': '已完成操作：',
    'File data processed: ': '已处理文件数据：',
    'Transferred data: ': '已传输数据：',
    'Verified data: ': '已校验数据：',
    'Elapsed: ': '已用时间：',
    'Folder: ': '目录：',
    'Current task: ': '当前任务：',
    'SQLite private file: ': 'SQLite 私有文件：',
    'Network: ': '网络：',
    'AppContainer: ': 'AppContainer：',
    'Credential Locker: ': '凭据保管库：',
    'Credential restart check: ': '凭据重启检查：',
    'Native capability: ': '原生能力：',
    'Broker capabilities: ': 'Broker 能力：',
    'Folder restart recovery: ': '目录重启恢复：',
    'Folder restart file I/O: ': '目录重启文件读写：',
    'Folder authorization: ': '目录授权：',
    'Marker: ': '标记：',
    'Reopen: ': '重新打开：',
    'File I/O: ': '文件读写：',
  };

  static const chinese = <String, String>{
    'Recovering previous sync': '正在恢复上次同步',
    'Scanning local music': '正在扫描本地音乐',
    'Hashing local music': '正在校验本地音乐',
    'Scanning cloud music': '正在扫描云端音乐',
    'Verifying local music': '正在复核本地音乐',
    'Verifying cloud music': '正在复核云端音乐',
    'Verifying cloud file': '正在校验云端文件',
    'Planning sync': '正在生成同步计划',
    'Uploading': '正在上传',
    'Downloading': '正在下载',
    'Deleting local file': '正在删除本地文件',
    'Deleting cloud file': '正在删除云端文件',
    'Preserving conflicting files': '正在保留冲突文件',
    'Updating favorites': '正在同步收藏',
    'File operations complete': '文件处理完成',
    'Saving sync result': '正在保存同步结果',
    'Scan': '扫描',
    'Transfer': '传输',
    'Verify': '校验',
    'Transferring files': '正在传输文件',
    'Verifying file integrity': '正在校验文件完整性',
    'Scanning & planning': '正在扫描与规划',
    'Checking file checksum (local integrity check, not re-downloading)':
        '正在校验本地文件完整性，非重新下载',
    'Scan music or start sync': '扫描音乐或开始同步',
    'Sync will scan local music automatically, or you can scan first.':
        '同步时将自动扫描本地音乐，也可以先手动扫描。',
    'Waiting for the current operation to respond…': '正在等待当前操作响应…',
    'Language': '语言',
    'App language': '应用语言',
    'Choose English or Chinese. Changes apply immediately.': '选择英文或中文，切换后立即生效。',
    'Session only': '仅本次运行有效',
    'English': '英文',
    'Chinese': '中文',
    'The selected language applies to this session. Preference storage is not connected yet.':
        '语言选择仅在本次运行中生效，偏好存储服务尚未连接。',
    'Could not save the language preference. The selected language still applies to this session.':
        '语言偏好保存失败，所选语言仍在本次运行中生效。',
    'Could not save preference.': '偏好保存失败。',
    'Music': '音乐',
    'Sync': '同步',
    'Settings': '设置',
    'Local services could not initialize': '本地服务初始化未完成',
    'Music library': '音乐库',
    'Scanning…': '扫描中…',
    'Scan music': '扫描音乐',
    'Music root folder unavailable': '音乐根目录不可用',
    'Folder access has expired. Select the music root folder again in Settings.':
        '授权已失效，请在设置中重新选择音乐根目录。',
    'No music root folder selected': '尚未选择音乐根目录',
    'Choose one in Settings.': '请在设置中选择目录。',
    'Select a music folder in Settings. SyncTune accesses only that folder.':
        '请在设置中选择音乐目录，SyncTune 只访问该目录。',
    'Checking folder access': '正在确认目录授权',
    'Scanning can start once folder access is confirmed.': '目录授权确认完成后才能开始扫描。',
    'Scanning music': '正在扫描音乐',
    'Reading music files in the authorized folder. Please wait.':
        '正在读取已授权目录中的音乐文件，请稍候。',
    'Scan incomplete': '扫描未完成',
    'Folder access changed. Reauthorize and retry.': '目录授权已变化，请重新授权后重试。',
    'Folder access or read status has changed. Select the folder again and retry.':
        '目录授权或读取状态已变化，请重新选择目录后重试。',
    'No music files found': '没有找到音乐文件',
    'Incomplete scan': '扫描不完整',
    'Only mp3, flac, wav, m4a, aac, ogg, and opus files are shown.':
        '仅显示 mp3、flac、wav、m4a、aac、ogg 和 opus 文件。',
    'Formats: mp3, flac, wav, m4a, aac, ogg, opus.':
        '支持格式：mp3、flac、wav、m4a、aac、ogg、opus。',
    'These results cannot be used to schedule deletions. Confirm folder access and scan again.':
        '当前结果不能用于安排删除，请确认授权后重新扫描。',
    'Currently readable files are shown. No deletions will be scheduled until a full scan is complete.':
        '已显示当前可读取的文件，完整扫描前不会安排删除。',
    'Ready to scan music': '可以扫描音乐',
    'Only your selected folder is accessed. Supported formats: mp3, flac, wav, m4a, aac, ogg, and opus.':
        '仅访问所选授权目录，支持 mp3、flac、wav、m4a、aac、ogg 和 opus。',
    'Select and authorize a folder to start scanning.': '选择并授权目录后开始扫描。',
    'SyncTune syncs music files. Playback and editing are unavailable.':
        'SyncTune 只同步音乐文件，不播放或编辑音乐。',
    'Favorites will be enabled once the local metadata service is connected.':
        '本地元数据服务连接后即可使用收藏功能。',
    'Favorites status': '收藏状态',
    'File': '文件',
    'Format': '格式',
    'Size': '大小',
    'Favorite': '收藏',
    'Favorites service disconnected': '收藏服务尚未连接',
    'Remove from favorites': '取消收藏',
    'Could not load favorites. The displayed favorites may be incomplete.':
        '收藏读取失败，当前显示的收藏可能不完整。',
    'Could not save favorites. Try again later.': '收藏保存失败，请稍后重试。',
    'Access and connection': '授权与连接',
    'Opening folder picker…': '正在打开系统选择器…',
    'Choose music root folder': '选择音乐根目录',
    'Revoking access…': '正在撤销授权…',
    'Revoke folder access': '撤销目录授权',
    'This platform does not provide an access revocation service.':
        '当前平台未提供撤销服务。',
    'Revocation unavailable on this platform.': '当前平台不支持撤销授权。',
    'Could not revoke folder access. The current authorization remains active.':
        '目录授权撤销失败，当前授权仍保持。',
    'Could not revoke access. Authorization remains active.': '授权撤销失败，当前授权仍有效。',
    'Open platform diagnostics': '打开平台诊断',
    'Appearance': '外观',
    'Use the system theme by default, or choose a light or dark theme for this device.':
        '默认跟随系统，也可以选择浅色或深色主题。',
    'Theme mode': '主题模式',
    'System': '跟随系统',
    'Light': '浅色',
    'Dark': '深色',
    'The selected theme applies to this session. Preference storage is not connected yet.':
        '主题选择仅在本次运行中生效，偏好存储服务尚未连接。',
    'Credentials and WebDAV': '凭据与 WebDAV',
    'Save the connection settings and complete compatibility checks to enable sync.':
        '保存连接设置并完成兼容性检查后即可启用同步。',
    'Permission status': '权限状态',
    'Sync requires verified platform permissions, folder access, a complete scan, remote compatibility, and platform safety checks.':
        '同步需要通过平台权限、目录授权、完整扫描、远端兼容性和平台安全检查。',
    'Please wait.': '请稍候。',
    'Folder access has expired. Select the music root folder again.':
        '授权已失效，请重新选择音乐根目录。',
    'Music root folder authorized': '音乐根目录已授权',
    'Choose the folder again.': '请重新选择目录。',
    'Only your selected folder is accessed.': '仅访问所选目录。',
    'Folder': '目录',
    'Select a music folder to start using SyncTune.': '请选择音乐目录开始使用 SyncTune。',
    'WebDAV URL': 'WebDAV 地址',
    'Username': '用户名',
    'Password': '密码',
    'Saving…': '保存中…',
    'Save WebDAV settings': '保存 WebDAV 设置',
    'The remote service is not connected. Saving is currently unavailable.':
        '远端服务尚未连接，暂时无法保存。',
    'WebDAV service unavailable.': 'WebDAV 服务不可用。',
    'Saved': '已保存',
    'Settings status': '设置状态',
    'The remote service is not connected': '远端服务尚未连接',
    'Enter a valid HTTPS WebDAV URL': '请输入有效的 HTTPS WebDAV 地址',
    'Settings saved': '设置已保存',
    'Could not save settings. Try again later.': '设置保存失败，请稍后重试。',
    'Old WebDAV credential cleanup failed. The current settings remain active.':
        '旧 WebDAV 凭据清理失败，当前设置仍已生效。',
    'Settings saved, but the runtime sync identity could not be updated.':
        '设置已保存，但运行时同步身份更新失败。',
    'Settings saved, but the runtime credential version could not be updated.':
        '设置已保存，但运行时凭据版本更新失败。',
    'Sync status': '同步状态',
    'Sync starts only after a complete folder scan and all safety checks pass.':
        '目录扫描完整且所有安全检查通过后才会执行同步。',
    'Cancel sync': '取消同步',
    'Retry': '重试',
    'Working…': '处理中…',
    'Start sync': '开始同步',
    'Check again': '重新检查',
    'Folder access expired': '目录授权已失效',
    'Select the music root folder again in Settings.': '请在设置中重新选择音乐根目录。',
    'Choose the folder again in Settings.': '请在设置中重新选择目录。',
    'Music root folder access required': '音乐根目录需要授权',
    'Select and authorize a music root folder before checking sync requirements.':
        '选择并授权音乐根目录后才能检查同步条件。',
    'Select a music folder in Settings.': '请在设置中选择音乐目录。',
    'Wait for folder access to be confirmed before continuing.':
        '请等待目录授权确认后继续。',
    'Scan in progress': '扫描进行中',
    'A safe sync plan can be created once the scan is complete.':
        '扫描完成后才能生成安全的同步计划。',
    'Finish the scan before syncing.': '请先完成扫描。',
    'Scan status unavailable': '扫描状态不可用',
    'Scan again on the Music page to confirm the entire folder is readable.':
        '请在音乐页面重新扫描，确认整个目录可读。',
    'Rescan on Music to confirm folder access.': '请在音乐页重新扫描并确认目录授权。',
    'Scan required': '需要扫描',
    'A partial scan cannot schedule deletions. Complete a full scan first.':
        '部分扫描不能安排删除，请先完成完整扫描。',
    'Partial scans cannot schedule deletions. Run a full scan.':
        '部分扫描不会安排删除，请重新完整扫描。',
    'Scan music before syncing.': '请先扫描音乐。',
    'Complete a scan on the Music page before checking sync requirements.':
        '请先在音乐页面完成扫描，再检查同步条件。',
    'Sync canceled': '同步已取消',
    'Sync incomplete': '同步未完成',
    'Sync complete': '同步已完成',
    'Sync unavailable': '同步尚未开放',
    'Sync blocked': '同步受阻',
    'The sync adapters and platform safety checks have not been verified. Sync is currently unavailable.':
        '同步适配器和平台安全检查尚未验证，当前无法同步。',
    'Check sync requirements': '检查同步条件',
    'Sync requires verified platform access, remote compatibility, and sync services.':
        '平台授权、远端兼容性和同步服务验证完成后才能同步。',
    'Waiting to sync': '等待同步',
    'Checking sync requirements': '正在检查同步条件',
    'Checking local access, the remote connection, and safety requirements.':
        '正在确认本地授权、远端连接和安全条件。',
    'Sync requirements check failed': '同步条件检查失败',
    'Check the connection and folder access, then retry.': '请检查连接和目录授权后重试。',
    'Sync in progress': '同步进行中',
    'Sync is running. Please wait.': '正在执行同步，请稍候。',
    'Local and remote content have been synced.': '本地与远端内容已完成同步。',
    'Sync requirements or the connection changed. Scan again and retry.':
        '同步条件或连接已变化，请重新扫描后重试。',
    'Sync root folder access required': '同步根目录需要授权',
    'The WebDAV URL is not configured': 'WebDAV 地址尚未配置',
    'WebDAV credentials are not configured': 'WebDAV 凭据尚未配置',
    'Sync waiting for authorization': '同步等待授权',
    'The authorized folder has changed. Confirm folder access again before syncing.':
        '授权目录已变化，请重新确认后再同步。',
    'Sync awaiting verification': '同步等待验证',
    'Platform file safety verification is incomplete. Sync is currently unavailable.':
        '平台文件安全验证尚未完成，当前无法同步。',
    'Platform file safety verification did not pass. Sync is currently unavailable.':
        '平台文件安全验证未通过，当前无法同步。',
    'Platform file safety evidence is unavailable. Sync is currently unavailable.':
        '平台文件安全证据不可用，当前无法同步。',
    'Platform requirements not met': '平台条件未满足',
    'Platform file safety capabilities are unavailable. Sync is currently unavailable.':
        '平台文件安全能力不可用，当前无法同步。',
    'Local file safety requirements have not been verified. Sync is currently unavailable.':
        '本地文件安全条件尚未验证，当前无法同步。',
    'Ready to sync': '同步已就绪',
    'Folder access, the remote connection, and safety requirements are verified.':
        '授权、远端连接和安全条件已验证。',
    'Remote connection not verified': '远端连接未验证',
    'WebDAV compatibility checks have not passed. Sync is currently unavailable.':
        'WebDAV 兼容性检查未通过，当前无法同步。',
    'Local data service initialization failed. Sync and favorites persistence are disabled.':
        '本地数据服务初始化失败，同步与收藏持久化已禁用。',
    'The platform did not provide a private database location. Sync and favorites persistence are disabled.':
        '平台未提供私有数据库位置，同步与收藏持久化已禁用。',
    'Sync service initialization failed. Sync remains disabled.':
        '同步服务初始化失败，同步保持禁用。',
    'Canceling sync': '正在取消同步',
    'The app is suspended. Sync will resume when the app returns.':
        '应用已挂起，返回应用后恢复同步。',
    'Syncing': '正在同步',
    'Sync did not finish. Check the connection and retry.': '同步未完成，请检查连接后重试。',
    'Folder or connection settings changed. Canceling the previous sync.':
        '目录或连接设置已变化，正在取消之前的同步。',
    'Waiting for the next foreground sync': '前台等待下一次同步',
    'SyncTune AppContainer Probe': 'SyncTune AppContainer 诊断',
    'Choose authorized folder': '选择授权目录',
    'Flutter packaged classic AppContainer capability check':
        'Flutter 打包式经典 AppContainer 能力检查',
    'Running startup probes…': '正在运行启动诊断…',
    'No folder selected': '尚未选择目录',
    'Opening Windows FolderPicker…': '正在打开 Windows 目录选择器…',
    'idle': '空闲',
    'running': '运行中',
    'checking': '检查中',
    'failed': '失败',
    'completed': '已完成',
    'cancelled': '已取消',
    'Delete': '删除',
    'Delete song': '删除歌曲',
    'Cancel': '取消',
    'Delete unavailable': '当前无法删除',
    'Delete local song and WebDAV copy. Other devices will delete it on their next sync.':
        '删除本机歌曲及 WebDAV 副本，其他设备将在下次同步时删除。',
    'Local file deleted, waiting to sync': '本机已删除，等待同步',
    'Song deletion failed': '删除歌曲失败',
  };
}

class _StringsDelegate extends LocalizationsDelegate<SyncTuneStrings> {
  const _StringsDelegate();
  @override
  bool isSupported(Locale locale) => ['en', 'zh'].contains(locale.languageCode);
  @override
  Future<SyncTuneStrings> load(Locale locale) =>
      SynchronousFuture(SyncTuneStrings(locale));
  @override
  bool shouldReload(_StringsDelegate old) => false;
}

class LocalizedText extends StatelessWidget {
  const LocalizedText(
    this.data, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow,
  });
  final String data;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  @override
  Widget build(BuildContext context) => Text(
    SyncTuneStrings.of(context).text(data),
    style: style,
    maxLines: maxLines,
    overflow: overflow,
  );
}
