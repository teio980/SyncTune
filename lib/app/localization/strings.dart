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
    'Enter the complete HTTPS URL, including the remote music directory.':
        '请输入完整的 HTTPS 地址，包含远程音乐目录。',
    'Username': '用户名',
    'Password': '密码',
    'Choose music folder': '选择音乐文件夹',
    'Choose a local music folder before saving.': '保存前请选择本地音乐文件夹。',
    'Enter an HTTPS WebDAV URL.': '请输入 HTTPS WebDAV 地址。',
    'Enter the WebDAV username.': '请输入 WebDAV 用户名。',
    'Enter the WebDAV password.': '请输入 WebDAV 密码。',
    'This password will be saved in the system credential store.':
        '此密码将保存到系统凭据存储中。',
    'A password is saved for this account. Leave blank to keep it.':
        '此账号已有已保存的密码。留空即可保留。',
    'Show saved password': '显示已保存密码',
    'Hide password': '隐藏密码',
    'Test connection': '测试连接',
    'Cancel connection test': '取消连接测试',
    'WebDAV connection successful.': 'WebDAV 连接成功。',
    'Enter a password or use an account with a saved password.':
        '请输入密码，或使用已有已保存密码的账号。',
    'Delete music?': '删除音乐？',
    'This removes the selected files from this device. The next sync will propagate deletion for songs already in the sync history. Songs not yet registered from WebDAV may download again on the first sync.':
        '这会从本设备删除所选歌曲。下次同步会传播已登记歌曲的删除；尚未登记的 WebDAV 歌曲可能在首次同步时重新下载。',
    'Cancel': '取消',
    'Delete locally': '本地删除',
    'Deleted locally. The next sync will compare both folders.':
        '已从本地删除。下次同步时会比较双方文件夹。',
    'Recover the previous sync before deleting music.': '请先恢复上次同步，再删除音乐。',
    'The selected folder changed; refresh the list.': '所选文件夹已变化，请刷新列表。',
    'Refresh': '刷新',
    'songs': '首歌曲',
    'No music files found.': '没有找到音乐文件。',
    'Choose a local music folder in Settings.': '请在设置中选择本地音乐文件夹。',
    'Music is listed from the selected folder. Deleting here removes only the chosen local song files.':
        '此处列出所选文件夹中的音乐。删除只会移除所选本地歌曲文件。',
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
    'No folder selected': '尚未选择文件夹',
    'Enter a relative WebDAV directory, or leave it blank for the URL folder.':
        '输入相对 WebDAV 目录；留空则使用地址对应的目录。',
    'Changes apply after Save. The password is held in the system credential store.':
        '保存后应用更改。密码保存在系统凭据存储中。',
    'Settings cannot change while synchronization is running.': '同步运行期间不能更改设置。',
    'The previous sync must recover before changing the folder or account.':
        '更改文件夹或账号前，必须先恢复上次同步。',
    'System': '跟随系统',
    'Selected': '已选择',
    'Files are matched by relative folder and filename. Sync starts only when you press Start.':
        '文件按相对文件夹和文件名对应。点击“开始同步”后才会运行。',
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
