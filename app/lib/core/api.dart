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

class Api {
  static Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? token,
  }) async {
    final uri = Uri.parse('${AppConfig.apiBase}$path');
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
      throw ApiException(0, 'Cannot reach server at ${AppConfig.serverUrl}');
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

  static Future<AuthResult> login({required String username, required String password}) async {
    final data = await _request('POST', '/login', body: {
      'username': username,
      'password': password,
    });
    return AuthResult(data['token'] as String, User.fromJson(data['user']));
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

  static Future<List<Conversation>> conversations(String token) async {
    final data = await _request('GET', '/conversations', token: token);
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

  static String attachmentUrl(String url) => AppConfig.serverUrl + url;
}