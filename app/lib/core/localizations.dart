import 'package:flutter/foundation.dart';

/// Lightweight two-language localization.
///
/// English strings stay the source key and are passed inline as the fallback
/// (no translation dictionary to drift from the UI), with the Russian string
/// provided at the call site. When `ru` is omitted the English text is used
/// in both languages, which keeps untranslated helpers safe.
class L {
  L._();

  static const List<String> supported = ['en', 'ru'];

  /// Current language code. The app listens to this notifier to rebuild.
  static ValueNotifier<String> current = ValueNotifier('en');

  static String get lang => current.value;

  static bool get isRu => lang == 'ru';

  static void setLang(String language) {
    if (supported.contains(language)) current.value = language;
  }

  static String t(String en, {String? ru}) => isRu ? (ru ?? en) : en;

  /// Russian has one/few/many plurals. `aar`-style: pick the right form for
  /// `n` when translating; English callers may pass a single "many" string
  /// that already contains the number.
  static String plural(
    int n, {
    required String enOne,
    required String enMany,
    String? ruOne,
    String? ruFew,
    String? ruMany,
  }) {
    if (!isRu) return n == 1 ? enOne : enMany;
    final rem10 = n % 10;
    final rem100 = n % 100;
    if (rem10 == 1 && rem100 != 11) return ruOne ?? enMany;
    if (rem10 >= 2 && rem10 <= 4 && !(rem100 >= 12 && rem100 <= 14)) {
      return ruFew ?? enMany;
    }
    return ruMany ?? enMany;
  }
}