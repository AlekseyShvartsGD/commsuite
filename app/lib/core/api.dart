import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models.dart';
import 'app_config.dart';

class ApiException implements Exception {
  final int status;
  final String message;

  ApiException(this.status, this.message);

  @override
  String toString() => message;
}

class AuthResult {
  final String token;
  final User user;

  AuthResult(this.token, this.user);
}

/// One step of sign-in: either a ready session, or a short-lived challenge
/// that must be exchanged for one with a TOTP or recovery code.
class LoginResult {
  final AuthResult? session;
  final String? challenge;

  const LoginResult.session(this.session) : challenge = null;
  const LoginResult.challenge(this.challenge) : session = null;

  bool get requiresTwoFactor => challenge != null;
}

class TwoFactorSetup {
  final String secret;
  final String otpauthUrl;

  const TwoFactorSetup({required this.secret, required this.otpauthUrl});
}

class TwoFactorStatus {
  final bool enabled;
  final int remainingRecoveryCodes;

  const TwoFactorStatus({
    required this.enabled,
    required this.remainingRecoveryCodes,
  });
}

class Api {
  static Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? token,
    String? baseUrl,
  }) async {
    final uri = Uri.parse('${baseUrl ?? AppConfig.apiBase}$path');
    final headers = <String, String>{
      if (body != null) 'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
    http.Response resp;
    try {
      switch (method) {
        case 'GET':
          resp = await http.get(uri, headers: headers);
          break;
        case 'POST':
          resp = await http.post(uri,
              headers: headers, body: body != null ? jsonEncode(body) : null);
          break;
        case 'PATCH':
          resp = await http.patch(uri,
              headers: headers, body: body != null ? jsonEncode(body) : null);
          break;
        case 'DELETE':
          resp = await http.delete(uri, headers: headers);
          break;
        default:
          throw UnsupportedError(method);
      }
    } catch (e) {
      throw ApiException(0, 'Cannot reach server at ${baseUrl ?? AppConfig.serverUrl}');
    }
    Map<String, dynamic>? data;
    try {
      data = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {}
    if (resp.statusCode >= 400) {
      throw ApiException(
          resp.statusCode, (data?['error'] as String?) ?? 'HTTP ${resp.statusCode}');
    }
    return data ?? {};
  }

  static Future<AuthResult> register({
    required String username,
    required String password,
    required String displayName,
    String bio = '',
  }) async {
    final data = await _request('POST', '/register', body: {
      'username': username,
      'password': password,
      'displayName': displayName,
      'bio': bio,
    });
    return AuthResult(data['token'] as String, User.fromJson(data['user']));
  }

  static Future<LoginResult> login({
    required String username,
    required String password,
  }) async {
    final data = await _request('POST', '/login', body: {
      'username': username,
      'password': password,
    });
    if (data['twoFactorRequired'] == true) {
      return LoginResult.challenge(data['challenge'] as String);
    }
    return LoginResult.session(
      AuthResult(data['token'] as String, User.fromJson(data['user'])),
    );
  }

  /// Exchanges the short-lived challenge from [login] plus a TOTP or recovery
  /// code for a real session token.
  static Future<AuthResult> loginTwoFactor({
    required String challenge,
    required String code,
  }) async {
    final data = await _request('POST', '/login/2fa', body: {
      'challenge': challenge,
      'code': code,
    });
    return AuthResult(data['token'] as String, User.fromJson(data['user']));
  }

  static Future<TwoFactorStatus> twoFactorStatus(String token) async {
    final data = await _request('GET', '/2fa/status', token: token);
    return TwoFactorStatus(
      enabled: data['enabled'] as bool? ?? false,
      remainingRecoveryCodes:
          (data['remainingRecoveryCodes'] as num?)?.toInt() ?? 0,
    );
  }

  static Future<TwoFactorSetup> startTwoFactorSetup(String token) async {
    final data = await _request('POST', '/2fa/setup', token: token);
    return TwoFactorSetup(
      secret: data['secret'] as String,
      otpauthUrl: data['otpauthUrl'] as String,
    );
  }

  static Future<List<String>> enableTwoFactor(
      String token, String code) async {
    final data = await _request('POST', '/2fa/enable',
        body: {'code': code}, token: token);
    return (data['recoveryCodes'] as List).cast<String>();
  }

  static Future<void> disableTwoFactor(
    String token, {
    required String password,
    required String code,
  }) async {
    await _request('POST', '/2fa/disable',
        body: {'password': password, 'code': code}, token: token);
  }

  static Future<void> changePassword(
    String token, {
    required String currentPassword,
    required String newPassword,
  }) async {
    await _request('POST', '/password', body: {
      'currentPassword': currentPassword,
      'newPassword': newPassword,
    }, token: token);
  }

  static Future<User> me(String token) async {
    final data = await _request('GET', '/me', token: token);
    return User.fromJson(data['user']);
  }

  static Future<User> user(String token, String id) async {
    final data = await _request('GET', '/users/$id', token: token);
    return User.fromJson(data['user']);
  }

  static Future<User> setBio(String token, String bio) async {
    final data = await _request('PATCH', '/me', body: {'bio': bio}, token: token);
    return User.fromJson(data['user']);
  }

  static Future<List<String>> blocks(String token) async {
    final data = await _request('GET', '/blocks', token: token);
    return (data['blockedIds'] as List).cast<String>();
  }

  static Future<void> setBlock(String token, String userId, {required bool blocked}) async {
    await _request('POST', '/block',
        body: {'targetId': userId, 'blocked': blocked}, token: token);
  }

  static Future<void> reportUser(String token, String userId, {String reason = ''}) async {
    await _request('POST', '/report',
        body: {'targetId': userId, 'reason': reason}, token: token);
  }

  /// Files an app crash (timestamp, log and device specs) to the developers.
  /// [token] is optional: crashes can happen before sign-in.
  static Future<void> reportCrash({
    required String timestamp,
    required String log,
    required String platform,
    Map<String, String> specs = const {},
    String appVersion = '',
    String? username,
    String? token,
  }) async {
    await _request('POST', '/crash-report', body: {
      'timestamp': timestamp,
      'log': log,
      'platform': platform,
      'appVersion': appVersion,
      'specs': specs,
      if (username != null && username.isNotEmpty) 'username': username,
    }, token: token);
  }

  static Future<void> clearMessages(String token, String conversationId) async {
    await _request('DELETE', '/conversations/$conversationId/messages', token: token);
  }

  static Future<List<Report>> reports(String token) async {
    final data = await _request('GET', '/reports', token: token);
    return (data['reports'] as List)
        .map((r) => Report.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  static Future<void> resolveReport(String token, String reporterId, String targetId) async {
    await _request('DELETE', '/reports/$reporterId/$targetId', token: token);
  }

  static Future<void> setBan(String token, String targetId, {required bool banned}) async {
    await _request('POST', '/ban', body: {'targetId': targetId, 'banned': banned}, token: token);
  }

  static Future<void> setVerified(String token, String targetId, {required bool verified}) async {
    await _request('POST', '/verified', body: {'targetId': targetId, 'verified': verified}, token: token);
  }

  static Future<List<User>> bannedUsers(String token) async {
    final data = await _request('GET', '/banned', token: token);
    return (data['users'] as List).map((u) => User.fromJson(u as Map<String, dynamic>)).toList();
  }

  static Future<ActiveGame?> activeGame(String token, String conversationId) async {
    final data = await _request('GET', '/conversations/$conversationId/games', token: token);
    final game = data['game'];
    if (game == null) return null;
    return ActiveGame.fromJson(game as Map<String, dynamic>);
  }

  static Future<ActiveGame> startGame(String token, String conversationId,
      {required String type, int? secret}) async {
    final data = await _request('POST', '/conversations/$conversationId/games', body: {
      'type': type,
      'secret': ?secret,
    }, token: token);
    return ActiveGame.fromJson(data['game']);
  }

  static Future<void> gameMove(String token, String gameId, {required String move}) async {
    await _request('POST', '/games/$gameId/moves', body: {'move': move}, token: token);
  }

  static Future<Message> flip(String token, String conversationId, {required String call}) async {
    final data =
        await _request('POST', '/conversations/$conversationId/flip', body: {'call': call}, token: token);
    return Message.fromJson(data['message']);
  }

  static Future<List<User>> users(String token, {String query = ''}) async {
    final data = await _request('GET', '/users?query=${Uri.encodeQueryComponent(query)}',
        token: token);
    return (data['users'] as List).map((u) => User.fromJson(u as Map<String, dynamic>)).toList();
  }

  static Future<List<Conversation>> conversations(
    String token, {
    String? baseUrl,
  }) async {
    final data = await _request(
      'GET',
      '/conversations',
      token: token,
      baseUrl: baseUrl,
    );
    return (data['conversations'] as List)
        .map((c) => Conversation.fromJson(c as Map<String, dynamic>))
        .toList();
  }

  static Future<Conversation> createConversation(String token, String peerId) async {
    final data = await _request('POST', '/conversations', body: {'peerId': peerId}, token: token);
    return Conversation.fromJson(data['conversation']);
  }

  static Future<Conversation> createGroup(String token,
      {required String name,
      String description = '',
      required List<String> memberIds}) async {
    final data = await _request('POST', '/conversations/group', body: {
      'name': name,
      'description': description,
      'memberIds': memberIds,
    }, token: token);
    return Conversation.fromJson(data['conversation']);
  }

  /// Opens (or reuses) the caller's support conversation. The server invites
  /// every moderator and stores [message] as the first ticket message.
  static Future<Conversation> requestSupport(String token,
      {String subject = '', required String message}) async {
    final data = await _request('POST', '/support', body: {
      'subject': subject,
      'message': message,
    }, token: token);
    return Conversation.fromJson(data['conversation']);
  }

  // --- Bots ---------------------------------------------------------------
  // Bots are real users on the server. These endpoints manage the bots owned
  // by the signed-in account and the keyword replies / mini-app attached to
  // each one.

  static Future<List<Bot>> bots(String token) async {
    final data = await _request('GET', '/bots', token: token);
    return (data['bots'] as List)
        .map((b) => Bot.fromJson(b as Map<String, dynamic>))
        .toList();
  }

  static Future<Bot> createBot(String token,
      {required String name,
      String description = '',
      String miniApp = 'none',
      String mode = 'api'}) async {
    final data = await _request('POST', '/bots', body: {
      'name': name,
      'description': description,
      'miniApp': miniApp,
      'mode': mode,
    }, token: token);
    return Bot.fromJson(data['bot']);
  }

  static Future<Bot> updateBot(String token, String botId,
      {String? name,
      String? description,
      String? miniApp,
      String? mode,
      bool? enabled}) async {
    final data = await _request('PATCH', '/bots/$botId', body: {
      'name': ?name,
      'description': ?description,
      'miniApp': ?miniApp,
      'mode': ?mode,
      'enabled': ?enabled,
    }, token: token);
    return Bot.fromJson(data['bot']);
  }

  static Future<void> deleteBot(String token, String botId) async {
    await _request('DELETE', '/bots/$botId', token: token);
  }

  static Future<Bot> addBotReply(String token, String botId,
      {required String trigger, required String reply}) async {
    final data = await _request('POST', '/bots/$botId/replies', body: {
      'trigger': trigger,
      'reply': reply,
    }, token: token);
    return Bot.fromJson(data['bot']);
  }

  static Future<Bot> deleteBotReply(
      String token, String botId, String replyId) async {
    final data =
        await _request('DELETE', '/bots/$botId/replies/$replyId', token: token);
    return Bot.fromJson(data['bot']);
  }

  /// Invalidates the old token and returns a bot with its new token.
  static Future<Bot> resetBotToken(String token, String botId) async {
    final data = await _request('POST', '/bots/$botId/token', token: token);
    return Bot.fromJson(data['bot']);
  }

  static Future<Conversation> conversation(String token, String conversationId) async {
    final data = await _request('GET', '/conversations/$conversationId', token: token);
    return Conversation.fromJson(data['conversation']);
  }

  static Future<Conversation> updateGroup(String token, String conversationId,
      {String? name, String? description}) async {
    final data = await _request('PATCH', '/conversations/$conversationId',
        body: {'name': name, 'description': description}, token: token);
    return Conversation.fromJson(data['conversation']);
  }

  static Future<Conversation> addGroupMember(
      String token, String conversationId, String userId) async {
    final data = await _request('POST', '/conversations/$conversationId/members',
        body: {'userId': userId}, token: token);
    return Conversation.fromJson(data['conversation']);
  }

  /// Removes [userId] (may be self to leave). Returns null when leaving the
  /// last member deleted the whole group.
  static Future<Conversation?> removeGroupMember(
      String token, String conversationId, String userId) async {
    final data =
        await _request('DELETE', '/conversations/$conversationId/members/$userId', token: token);
    final conv = data['conversation'];
    return conv == null ? null : Conversation.fromJson(conv as Map<String, dynamic>);
  }

  static Future<Conversation> setGroupMemberRole(
      String token, String conversationId, String userId, String role) async {
    final data = await _request('PATCH', '/conversations/$conversationId/members/$userId',
        body: {'role': role}, token: token);
    return Conversation.fromJson(data['conversation']);
  }

  static Future<Conversation> setGroupMute(
      String token, String conversationId, {required bool muted}) async {
    final data = await _request('POST', '/conversations/$conversationId/mute',
        body: {'muted': muted}, token: token);
    return Conversation.fromJson(data['conversation']);
  }

  static Future<void> deleteGroup(String token, String conversationId) async {
    await _request('DELETE', '/conversations/$conversationId', token: token);
  }

  static Future<List<Message>> messages(String token, String conversationId,
      {int? before, int limit = 50}) async {
    final b = before != null ? '&before=$before' : '';
    final data = await _request(
        'GET', '/conversations/$conversationId/messages?limit=$limit$b', token: token);
    return (data['messages'] as List)
        .map((m) => Message.fromJson(m as Map<String, dynamic>))
        .toList();
  }

  static Future<Message> sendMessage(String token, String conversationId,
      {required String kind, String? body, String? attachmentId, String? replyTo}) async {
    final data = await _request('POST', '/conversations/$conversationId/messages', body: {
      'kind': kind,
      'body': body,
      'attachmentId': ?attachmentId,
      'replyTo': ?replyTo,
    }, token: token);
    return Message.fromJson(data['message']);
  }

  static Future<Message> editMessage(String token, String messageId, String body) async {
    final data = await _request('PATCH', '/messages/$messageId', body: {'body': body}, token: token);
    return Message.fromJson(data['message']);
  }

  static Future<Message> deleteMessage(String token, String messageId) async {
    final data = await _request('DELETE', '/messages/$messageId', token: token);
    return Message.fromJson(data['message']);
  }

  static Future<Message> forwardMessage(
      String token, String messageId, String conversationId) async {
    final data = await _request(
        'POST', '/messages/$messageId/forward', body: {'conversationId': conversationId},
        token: token);
    return Message.fromJson(data['message']);
  }

  static Future<Message> setMessagePinned(
      String token, String messageId, {required bool pinned}) async {
    final data = await _request(
        'POST', '/messages/$messageId/pin', body: {'pinned': pinned}, token: token);
    return Message.fromJson(data['message']);
  }

  static Future<Message> setReaction(String token, String messageId, String emoji) async {
    final data = await _request(
        'POST', '/messages/$messageId/reactions', body: {'emoji': emoji}, token: token);
    return Message.fromJson(data['message']);
  }

  static Future<List<Message>> pinnedMessages(String token, String conversationId) async {
    final data = await _request('GET', '/conversations/$conversationId/pinned', token: token);
    return (data['messages'] as List)
        .map((m) => Message.fromJson(m as Map<String, dynamic>))
        .toList();
  }

  static Future<Attachment> uploadFile(String token, String filePath, {required String filename}) async {
    final uri = Uri.parse('${AppConfig.apiBase}/attachments');
    final req = http.MultipartRequest('POST', uri);
    req.headers['Authorization'] = 'Bearer $token';
    req.files.add(await http.MultipartFile.fromPath('file', filePath, filename: filename));
    http.Response resp;
    try {
      final streamed = await req.send();
      resp = await http.Response.fromStream(streamed);
    } catch (e) {
      throw ApiException(0, 'Cannot reach server at ${AppConfig.serverUrl}');
    }
    Map<String, dynamic>? data;
    try {
      data = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {}
    if (resp.statusCode >= 400) {
      throw ApiException(resp.statusCode, (data?['error'] as String?) ?? 'upload failed');
    }
    return Attachment.fromJson(data!['attachment']);
  }

  // --- Live streaming ------------------------------------------------------
  // A channel is a persistent profile; going live snapshots it into a session
  // that the directory lists. Media never touches these endpoints.

  static Future<({StreamChannel channel, StreamInfo? live})> myStream(
      String token) async {
    final data = await _request('GET', '/streams/mine', token: token);
    final live = data['live'];
    return (
      channel: StreamChannel.fromJson(
          Map<String, dynamic>.from(data['channel'] as Map? ?? const {})),
      live: live == null
          ? null
          : StreamInfo.fromJson(Map<String, dynamic>.from(live as Map)),
    );
  }

  static Future<({StreamChannel channel, StreamInfo? live})> saveStreamChannel(
    String token, {
    String? title,
    String? description,
    String? game,
    String? visibility,
    int? slowMode,
  }) async {
    final data = await _request('PATCH', '/streams/channel', body: {
      'title': ?title,
      'description': ?description,
      'game': ?game,
      'visibility': ?visibility,
      'slowMode': ?slowMode,
    }, token: token);
    final live = data['live'];
    return (
      channel: StreamChannel.fromJson(
          Map<String, dynamic>.from(data['channel'] as Map? ?? const {})),
      live: live == null
          ? null
          : StreamInfo.fromJson(Map<String, dynamic>.from(live as Map)),
    );
  }

  static Future<List<StreamInfo>> streams(String token) async {
    final data = await _request('GET', '/streams', token: token);
    return (data['streams'] as List)
        .map((s) => StreamInfo.fromJson(s as Map<String, dynamic>))
        .toList();
  }

  static Future<List<String>> streamGames(String token) async {
    final data = await _request('GET', '/streams/games', token: token);
    return (data['games'] as List).cast<String>();
  }

  static Future<StreamInfo> stream(String token, String id) async {
    final data = await _request('GET', '/streams/$id', token: token);
    return StreamInfo.fromJson(data['stream']);
  }

  static Future<StreamLaunch> goLive(
    String token, {
    String? title,
    String? description,
    String? game,
    String? visibility,
    int? slowMode,
  }) async {
    final data = await _request('POST', '/streams', body: {
      'title': ?title,
      'description': ?description,
      'game': ?game,
      'visibility': ?visibility,
      'slowMode': ?slowMode,
    }, token: token);
    return StreamLaunch(
      stream: StreamInfo.fromJson(data['stream']),
      chatId: data['chatId'] as String? ?? '',
    );
  }

  static Future<StreamLaunch> joinStream(String token, String id) async {
    final data = await _request('POST', '/streams/$id/join', token: token);
    return StreamLaunch(
      stream: StreamInfo.fromJson(data['stream']),
      chatId: data['chatId'] as String? ?? '',
    );
  }

  static Future<void> leaveStream(String token, String id) async {
    await _request('POST', '/streams/$id/leave', token: token);
  }

  static Future<void> endStream(String token, String id) async {
    await _request('POST', '/streams/$id/end', token: token);
  }

  static Future<List<StreamViewer>> streamViewers(String token, String id) async {
    final data = await _request('GET', '/streams/$id/viewers', token: token);
    return (data['viewers'] as List)
        .map((v) => StreamViewer.fromJson(v as Map<String, dynamic>))
        .toList();
  }

  static Future<void> kickStreamViewer(
      String token, String id, String userId) async {
    await _request('POST', '/streams/$id/kick',
        body: {'userId': userId}, token: token);
  }

  static Future<void> banStreamViewer(
      String token, String id, String userId) async {
    await _request('POST', '/streams/$id/ban',
        body: {'userId': userId}, token: token);
  }

  static Future<void> unbanStreamViewer(
      String token, String id, String userId) async {
    await _request('DELETE', '/streams/$id/ban/$userId', token: token);
  }

  static Future<List<User>> streamBans(String token, String id) async {
    final data = await _request('GET', '/streams/$id/bans', token: token);
    return (data['bans'] as List)
        .map((u) => User.fromJson(u as Map<String, dynamic>))
        .toList();
  }

  static Future<List<User>> streamMods(String token, String id) async {
    final data = await _request('GET', '/streams/$id/mods', token: token);
    return (data['mods'] as List)
        .map((u) => User.fromJson(u as Map<String, dynamic>))
        .toList();
  }

  static Future<void> addStreamMod(
      String token, String id, String userId) async {
    await _request('POST', '/streams/$id/mods',
        body: {'userId': userId}, token: token);
  }

  static Future<void> removeStreamMod(
      String token, String id, String userId) async {
    await _request('DELETE', '/streams/$id/mods/$userId', token: token);
  }

  static String attachmentUrl(String url) => AppConfig.serverUrl + url;
}