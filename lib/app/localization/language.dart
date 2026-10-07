import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum AppLanguage {
  english('en'),
  chinese('zh');

  const AppLanguage(this.code);
  final String code;
  Locale get locale => Locale(code);

  static AppLanguage fromCode(String? code) =>
      code == 'en' ? AppLanguage.english : AppLanguage.chinese;
}

abstract interface class LanguagePreferencePort {
  Future<AppLanguage> load();
  Future<void> save(AppLanguage language);
}

final languagePreferencePortProvider = Provider<LanguagePreferencePort?>(
  (ref) => null,
);

class LanguageState {
  const LanguageState(this.language, {this.saveFailed = false});
  final AppLanguage language;
  final bool saveFailed;
}

final class LanguageViewModel extends Notifier<LanguageState> {
  int _revision = 0;
  bool _disposed = false;
  Future<void> _saves = Future<void>.value();

  @override
  LanguageState build() {
    ref.onDispose(() => _disposed = true);
    final port = ref.read(languagePreferencePortProvider);
    if (port != null) _load(port);
    return const LanguageState(AppLanguage.chinese);
  }

  Future<void> _load(LanguagePreferencePort port) async {
    final revision = _revision;
    try {
      final language = await port.load();
      if (!_disposed && revision == _revision) state = LanguageState(language);
    } catch (_) {
      // Keep Simplified Chinese if preference storage cannot be read.
    }
  }

  Future<void> select(AppLanguage language) {
    if (_disposed) return Future<void>.value();
    final revision = ++_revision;
    state = LanguageState(language);
    final port = ref.read(languagePreferencePortProvider);
    if (port == null) return Future<void>.value();
    // Serialize writes so a slow earlier save cannot replace the latest choice.
    _saves = _saves.then((_) async {
      try {
        await port.save(language);
      } catch (_) {
        if (!_disposed && revision == _revision) {
          state = LanguageState(language, saveFailed: true);
        }
      }
    });
    return _saves;
  }
}

final languageProvider = NotifierProvider<LanguageViewModel, LanguageState>(
  LanguageViewModel.new,
);
