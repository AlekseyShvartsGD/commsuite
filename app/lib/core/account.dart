import '../models.dart';

/// One saved sign-in. A Commsuite install can keep several accounts and switch
/// between them without signing in again.
///
/// The [id] is stable for a given user on a given server, so signing in again
/// updates the existing entry instead of adding a duplicate.
class AccountRecord {
  AccountRecord({
    required this.id,
    required this.userId,
    required this.username,
    required this.displayName,
    required this.serverUrl,
    required this.token,
    this.verified = false,
    this.remember = true,
    this.unread = 0,
    this.lastUsedAt = 0,
  });

  final String id;
  final String userId;
  final String serverUrl;
  String username;
  String displayName;
  String token;
  bool verified;

  /// When false the account is only kept for the current session and is
  /// dropped on the next launch (mirrors the "Remember me" checkbox).
  bool remember;

  /// Unread conversations last seen while this account was active (or fetched
  /// from the server when switching). Used for the switcher badges.
  int unread;

  /// Millis since epoch; the most recently used account is restored on launch.
  int lastUsedAt;

  String get handle => '@$username';

  String get label {
    final name = displayName.trim();
    return name.isEmpty ? username : name;
  }

  String get serverHost => Uri.tryParse(serverUrl)?.host ?? serverUrl;

  static String keyFor(String serverUrl, String userId) => '$serverUrl|$userId';

  factory AccountRecord.fromUser(
    User user, {
    required String serverUrl,
    required String token,
    bool remember = true,
  }) => AccountRecord(
    id: keyFor(serverUrl, user.id),
    userId: user.id,
    username: user.username,
    displayName: user.displayName,
    serverUrl: serverUrl,
    token: token,
    verified: user.isVerified,
    remember: remember,
    lastUsedAt: DateTime.now().millisecondsSinceEpoch,
  );

  factory AccountRecord.fromJson(Map<String, dynamic> json) => AccountRecord(
    id: json['id'] as String? ?? '',
    userId: json['userId'] as String? ?? '',
    username: json['username'] as String? ?? '',
    displayName: json['displayName'] as String? ?? '',
    serverUrl: json['serverUrl'] as String? ?? '',
    token: json['token'] as String? ?? '',
    verified: json['verified'] as bool? ?? false,
    remember: json['remember'] as bool? ?? true,
    unread: (json['unread'] as num?)?.toInt() ?? 0,
    lastUsedAt: (json['lastUsedAt'] as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'userId': userId,
    'username': username,
    'displayName': displayName,
    'serverUrl': serverUrl,
    'token': token,
    'verified': verified,
    'remember': remember,
    'unread': unread,
    'lastUsedAt': lastUsedAt,
  };

  void touch() {
    lastUsedAt = DateTime.now().millisecondsSinceEpoch;
  }
}
