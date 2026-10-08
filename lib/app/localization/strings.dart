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
    'Settings': '设置',
    'Start sync': '开始同步',
    'Cancel sync': '取消同步',
    'Open settings': '打开设置',
    'Local folder': '本地文件夹',
    'WebDAV folder': 'WebDAV 文件夹',
    'Server URL': '服务器地址',
    'Remote folder': '远程目录',
    'Username': '用户名',
    'Password': '密码',
    'Choose music folder': '选择音乐文件夹',
    'Choose a local music folder before saving.': '保存前请选择本地音乐文件夹。',
    'Enter an HTTPS WebDAV URL.': '请输入 HTTPS WebDAV 地址。',
    'Enter the WebDAV username.': '请输入 WebDAV 用户名。',
    'Enter the WebDAV password.': '请输入 WebDAV 密码。',
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
