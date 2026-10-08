import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

final class SyncTuneStrings {
  const SyncTuneStrings(this.locale);
  final Locale locale;

  static SyncTuneStrings of(BuildContext context) =>
      Localizations.of<SyncTuneStrings>(context, SyncTuneStrings) ??
      const SyncTuneStrings(Locale('en'));

  static const delegate = _StringsDelegate();
  static const supportedLocales = <Locale>[Locale('en'), Locale('zh')];

  String text(String value) =>
      locale.languageCode == 'zh' ? _zh[value] ?? value : value;

  static const Map<String, String> _zh = <String, String>{
    'SyncTune': 'SyncTune',
    'SyncTune could not initialize its local state.': 'SyncTune 无法初始化本地状态。',
    'Ready': '就绪',
    'Sync': '同步',
    'Music': '音乐',
    'Settings': '设置',
    'Start sync': '开始同步',
    'Cancel sync': '取消同步',
    'Open settings': '打开设置',
    'Local folder': '本地文件夹',
    'WebDAV URL': 'WebDAV 地址',
    'Include the remote music folder in the HTTPS URL.': 'HTTPS 地址中需包含远端音乐目录。',
    'Username': '用户名',
    'Password': '密码',
    'Choose music folder': '选择音乐文件夹',
    'Choose a local music folder before saving.': '保存前请选择本地音乐文件夹。',
    'Enter an HTTPS WebDAV URL.': '请输入 HTTPS WebDAV 地址。',
    'Enter the WebDAV username.': '请输入 WebDAV 用户名。',
    'Enter the WebDAV password.': '请输入 WebDAV 密码。',
    'Stored in system credentials.': '保存在系统凭据中。',
    'Leave blank to keep saved password.': '留空以保留已保存的密码。',
    'Show saved password': '显示已保存密码',
    'Hide password': '隐藏密码',
    'Test connection': '测试连接',
    'Cancel connection test': '取消连接测试',
    'WebDAV connection successful.': 'WebDAV 连接成功。',
    'Enter a password or use an account with a saved password.':
        '请输入密码，或使用已有已保存密码的账号。',
    'Delete songs?': '删除所选歌曲？',
    'Selected songs will be deleted now. Songs in sync history will also be deleted from WebDAV on the next sync. Unregistered WebDAV songs may be downloaded again on the first sync.':
        '所选歌曲会立即删除；已登记同步的歌曲也会在下次同步时从 WebDAV 删除。尚未登记的云端歌曲可能在首次同步时重新下载。',
    'Cancel': '取消',
    'Delete songs': '删除歌曲',
    'Delete song': '删除歌曲',
    'Deleted selected songs. Songs in sync history will also be deleted from WebDAV on the next sync.':
        '已删除所选歌曲。已登记同步的歌曲也会在下次同步时从 WebDAV 删除。',
    'Recover the previous sync before deleting music.': '请先恢复上次同步，再删除音乐。',
    'The selected folder changed; refresh the list.': '所选文件夹已变化，请刷新列表。',
    'Refresh': '刷新',
    'songs': '首歌曲',
    'No music files found.': '没有找到音乐文件。',
    'Choose a local music folder in Settings.': '请在设置中选择本地音乐文件夹。',
    'Save settings': '保存设置',
    'Language': '语言',
    'English': '英语',
    '简体中文': '简体中文',
    'Saved': '已保存',
    'Saving…': '正在保存…',
    'Running': '同步中',
    'Recovering previous work': '正在恢复上次任务',
    'Scanning files': '正在扫描文件',
    'Comparing files': '正在比较文件',
    'Transferring files': '正在传输文件',
    'Verifying both folders': '正在复核双方文件夹',
    'Saving sync state': '正在保存同步记录',
    'Sync complete': '同步完成',
    'Sync cancelled': '同步已取消',
    'Sync failed': '同步失败',
    'Files': '文件',
    'Data': '数据',
    'Files scanned': '已扫描文件',
    'Data read': '已读取数据',
    'Files processed': '已处理文件',
    'Data to transfer': '待传输数据',
    'Data transferred': '已传输数据',
    'Files verified': '已复核文件',
    'No folder selected': '尚未选择文件夹',
    'The previous sync must recover before changing the folder or account.':
        '更改文件夹或账号前，必须先恢复上次同步。',
    'System': '跟随系统',
    'Selected': '已选择',
  };
}

final class _StringsDelegate extends LocalizationsDelegate<SyncTuneStrings> {
  const _StringsDelegate();
  @override
  bool isSupported(Locale locale) =>
      const <String>{'en', 'zh'}.contains(locale.languageCode);
  @override
  Future<SyncTuneStrings> load(Locale locale) =>
      SynchronousFuture<SyncTuneStrings>(SyncTuneStrings(locale));
  @override
  bool shouldReload(_StringsDelegate old) => false;
}

final class LocalizedText extends StatelessWidget {
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
