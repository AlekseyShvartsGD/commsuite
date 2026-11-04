import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'hexagon_models.dart';

/// Keeps an unfinished map-maker draft on this device so closing the screen
/// (or the app) does not throw away ten minutes of tuning.
class HexDraftStore {
  HexDraftStore._();

  static const String _key = 'hexagon_map_maker_draft_v1';

  static Future<HexMapDraft?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return HexMapDraft.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(HexMapDraft draft) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(draft.toJson()));
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
