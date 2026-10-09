import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/app_config.dart';
import '../core/realtime.dart';
import '../models.dart';
import '../screens/call/call_screen.dart';
import 'notification_service.dart';
import 'os_notifications.dart';
import 'sound.dart';
import 'tray_service.dart';
import 'webrtc_service.dart';

import '../core/localizations.dart';

class CommsController extends ChangeNotifier {
  final RealtimeChannel channel = RealtimeChannel();
  final WebRTCService webrtc = WebRTCService();

  User? user;
  String? token;
  bool busy = true;

  final List<Conversation> conversations = [];
  final Map<String, List<Message>> _messages = {};
  final Map<String, List<Message>> _pinned = {};
  final Map<String, ActiveGame?> _activeGames = {};
  final Map<String, Set<String>> _typing = {};
  final Map<String, String> _fileSending = {};
  final Map<String, String> _fileSendingUsers = {};
  final Map<String, Timer> _fileSendingTimers = {};
  final Set<String> onlineIds = {};
  final Set<String> blockedIds = {};
  final Set<String> _completedLoads = {};

  static const _messagePageSize = 50;
  final Set<String> _olderLoadsInFlight = {};
  final Map<String, int> _messageLoadGen = {};

  String? _activeConversation;
  CallSession? call;
  StreamSubscription? _sub;
  final Map<String, Timer> _typingTimers = {};

  Timer? _pingTimer;
  Timer? _authRetry;
  Timer? _ringTimer;
  final GlobalKey<ScaffoldMessengerState> messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  bool get authed => user != null;
  bool conversationsLoaded = false;

  /// The realtime socket has finished its handshake. Until the server responds
  /// (it can take 10-20 s after launch) calls must NOT touch WebRTC: setting up
  /// peer connections in that window aborts the native addTrack code on Android.
  bool get socketConnected => channel.connected.value;

  /// A saved (remembered) session exists but the user isn't authenticated yet:
  /// the app is (re)connecting to the saved server in the background. The UI
  /// shows the "redirecting to your server" screen while this is true.
  bool get serverConnecting => token != null && user == null;

  /// Drops the remembered session and returns to the plain login screen.
  void startFreshSession() {
    _authRetry?.cancel();
    _clearAuth();
    notifyListeners();
  }

  List<Message> messages(String conversationId) =>
      _messages[conversationId] ?? const <Message>[];

  ActiveGame? activeGame(String conversationId) => _activeGames[conversationId];

  Future<void> _refreshGame(String conversationId) async {
    final t = token;
    if (t == null) return;
    try {
      _activeGames[conversationId] = await Api.activeGame(t, conversationId);
      notifyListeners();
    } on ApiException {
      // transient; the panel hides itself when the game ends
    }
  }

  /// Starts a new minigame in [conversationId]. [secret] is used by 'guess'.
  Future<bool> startGame(
    String conversationId, {
    required String type,
    int? secret,
  }) async {
    final t = token;
    if (t == null) return false;
    try {
      final game = await Api.startGame(
        t,
        conversationId,
        type: type,
        secret: secret,
      );
      _activeGames[conversationId] = game;
      await loadMessages(conversationId);
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      showSnack(e.message);
      return false;
    }
  }

  /// Sends a move (rps: rock/paper/scissors, guess: number as string).
  Future<void> playMove(
    String conversationId,
    String gameId,
    String move,
  ) async {
    final t = token;
    if (t == null) return;
    try {
      await Api.gameMove(t, gameId, move: move);
      await _refreshGame(conversationId);
      await loadMessages(conversationId);
    } on ApiException catch (e) {
      showSnack(e.message);
    }
  }

  /// Flips a coin ('heads'/'tails') and posts the result as a message.
  Future<void> flipCoin(String conversationId, String call) async {
    final t = token;
    if (t == null) return;
    try {
      await Api.flip(t, conversationId, call: call);
      await loadMessages(conversationId);
    } on ApiException catch (e) {
      showSnack(e.message);
    }
  }

  /// Requests the current active-game state for a conversation.
  Future<void> refreshActiveGame(String conversationId) async {
    await _refreshGame(conversationId);
  }

  /// Hides the in-chat game panel (the game stays alive server-side).
  void dismissGamePanel(String conversationId) {
    _activeGames[conversationId] = null;
    notifyListeners();
  }

  bool isOnline(String userId) => onlineIds.contains(userId);

  bool isBlocked(String userId) => blockedIds.contains(userId);

  String? typingUser(String conversationId) {
    final set = _typing[conversationId];
    if (set == null || set.isEmpty) return null;
    return set.first;
  }

  /// Filename the peer is currently sending in [conversationId], if any.
  String? fileSendingName(String conversationId) =>
      _fileSending[conversationId];

  /// Id of the user currently sending a file in [conversationId], if any.
  String? fileSendingUser(String conversationId) =>
      _fileSendingUsers[conversationId];

  List<Conversation> get sortedConversations {
    final list = List<Conversation>.from(conversations);
    list.sort((a, b) {
      final at = a.lastMessage?.createdAt ?? a.createdAt;
      final bt = b.lastMessage?.createdAt ?? b.createdAt;
      return bt.compareTo(at);
    });
    return list;
  }

  Future<void> bootstrap() async {
    await AppConfig.init();
    _sub ??= channel.events.listen(_onEvent);
    channel.connected.addListener(_onSocketConnectedChanged);
    unawaited(_initOsNotifications());
    final savedToken = await AppConfig.loadToken();
    if (savedToken != null) {
      token = savedToken;
      _autoconnect();
    }
    busy = false;
    notifyListeners();
  }

  /// Mirrors the realtime socket state into the Windows tray menu/tooltip.
  void _onSocketConnectedChanged() {
    TrayService.instance.setConnectionStatus(channel.connected.value);
  }

  Future<void> _initOsNotifications() async {
    OsNotifications.instance.onCallAnswer = (peerId) async {
      final s = call;
      if (s != null && !s.outgoing && (peerId.isEmpty || s.peer.id == peerId)) {
        await acceptCall();
      }
    };
    OsNotifications.instance.onCallDecline = (peerId) async {
      final s = call;
      if (s != null && !s.outgoing && (peerId.isEmpty || s.peer.id == peerId)) {
        await declineCall();
      }
    };
    OsNotifications.instance.onOpen = () {
      if (Platform.isWindows) {
        TrayService.instance.bringToFrontTopCenter();
      } else {
        OsNotifications.instance.bringToFront();
      }
    };
    await OsNotifications.instance.init();
  }

  /// Restores a saved session without wiping it on transient server outages.
  void _autoconnect() {
    final t = token;
    if (t == null) {
      _authRetry?.cancel();
      return;
    }
    _authRetry?.cancel();
    _authRetry = Timer(const Duration(seconds: 2), () async {
      try {
        final me = await Api.me(t);
        if (!_autoconnectGuard(t)) return;
        user = me;
        channel.connect(AppConfig.wsUrlWithToken(t));
        unawaited(refreshBlocks());
        notifyListeners();
      } on ApiException catch (e) {
        if (e.status == 401) {
          await _clearAuth(); // session expired -> back to the auth screen
          notifyListeners();
          return;
        }
        _autoconnect(); // server unreachable yet: keep the token and retry
      } catch (_) {
        _autoconnect();
      }
    });
  }

  bool _autoconnectGuard(String t) => token == t && user == null;

  Future<String?> register(
    String username,
    String password,
    String displayName, {
    String bio = '',
  }) async {
    try {
      final res = await Api.register(
        username: username,
        password: password,
        displayName: displayName,
        bio: bio,
      );
      _applyAuth(res.token, res.user);
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (_) {
      return L.t(
        'Could not reach the server.',
        ru: 'Не удалось связаться с сервером.',
      );
    }
  }

  Future<String?> login(String username, String password) async {
    try {
      final res = await Api.login(username: username, password: password);
      _applyAuth(res.token, res.user);
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (_) {
      return L.t(
        'Could not reach the server.',
        ru: 'Не удалось связаться с сервером.',
      );
    }
  }

  void _applyAuth(String newToken, User newUser) {
    _authRetry?.cancel();
    token = newToken;
    user = newUser;
    if (AppConfig.rememberMe) {
      AppConfig.saveToken(newToken);
    } else {
      AppConfig.clearToken(); // session only: forget it on app restart
    }
    channel.connect(AppConfig.wsUrlWithToken(newToken));
    conversations.clear();
    _messages.clear();
    _typing.clear();
    onlineIds.clear();
    blockedIds.clear();
    _completedLoads.clear();
    _activeConversation = null;
    unawaited(refreshBlocks());
    notifyListeners();
  }

  Future<void> reconnect() async {
    final t = token;
    if (t == null) return;
    channel.connect(AppConfig.wsUrlWithToken(t));
    notifyListeners();
  }

  /// After the OS freezes/suspends the process (background, screen off) the
  /// socket can be closed server-side; reconnect on resume if it dropped.
  void reconnectIfNeeded() {
    if (!channel.connected.value && token != null) {
      unawaited(reconnect());
    }
  }

  Future<void> logout() async {
    _authRetry?.cancel();
    await _finalizeCall();
    channel.disconnect();
    await _clearAuth();
    conversations.clear();
    _messages.clear();
    _typing.clear();
    onlineIds.clear();
    blockedIds.clear();
    _completedLoads.clear();
    _activeConversation = null;
    conversationsLoaded = false;
    notifyListeners();
  }

  Future<void> _clearAuth() async {
    token = null;
    user = null;
    await AppConfig.clearToken();
  }

  void _onEvent(Map<String, dynamic> event) {
    switch (event['type']) {
      case 'hello':
        final online = event['online'];
        if (online is List) {
          onlineIds.clear();
          onlineIds.addAll(online.cast<String>());
        }
        _startPing();
        notifyListeners();
        break;

      case 'presence':
        final id = event['userId'] as String?;
        if (id == null) break;
        if (event['online'] == true) {
          onlineIds.add(id);
        } else {
          onlineIds.remove(id);
        }
        notifyListeners();
        break;

      case 'message':
        _onIncomingMessage(Map<String, dynamic>.from(event));
        break;

      case 'message-updated':
      case 'message-deleted':
      case 'message-pinned':
      case 'message-reactions':
        {
          final convId = event['conversationId'] as String?;
          final raw = event['message'];
          if (convId != null && raw is Map) {
            _applyMessageUpdate(
              convId,
              Message.fromJson(Map<String, dynamic>.from(raw)),
            );
          }
          break;
        }

      case 'typing':
        _onTyping(Map<String, dynamic>.from(event));
        break;

      case 'file-sending':
        _onFileSending(Map<String, dynamic>.from(event));
        break;

      case 'read':
        _onReadEvent(Map<String, dynamic>.from(event));
        break;

      case 'group-updated':
      case 'group-added':
        unawaited(refreshConversations());
        break;

      case 'group-removed':
      case 'group-deleted':
        {
          final convId = event['conversationId'] as String?;
          if (convId != null) _removeConversation(convId);
          break;
        }

      case 'game':
        final convId = event['conversationId'] as String?;
        if (convId != null) {
          _refreshGame(convId);
          loadMessages(convId);
        }
        break;

      case 'signal':
        final from = event['from'] is Map
            ? Map<String, dynamic>.from(event['from'])
            : <String, dynamic>{};
        if (from['id'] != null) {
          _handleSignal(
            from,
            event['kind'] as String? ?? '',
            event['payload'] is Map
                ? Map<String, dynamic>.from(event['payload'])
                : null,
          );
        }
        break;

      case 'error':
        showSnack(
          event['message'] as String? ??
              L.t('server error', ru: 'ошибка сервера'),
        );
        break;
    }
  }

  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      channel.send({'type': 'ping'});
    });
  }

  void showSnack(String message) {
    messengerKey.currentState?.showSnackBar(SnackBar(content: Text(message)));
  }

  void _onIncomingMessage(Map<String, dynamic> event) {
    final conversationId = event['conversationId'] as String?;
    if (conversationId == null) return;
    final message = Message.fromJson(
      Map<String, dynamic>.from(event['message']),
    );
    if (message.kind == MessageKind.file) {
      // The file arrived; the "sending <name>…" cue is no longer needed.
      _fileSending.remove(conversationId);
      _fileSendingUsers.remove(conversationId);
      _fileSendingTimers[conversationId]?.cancel();
    }
    final list = _messages.putIfAbsent(conversationId, () => <Message>[]);
    if (list.any((m) => m.id == message.id)) {
      return; // dedup (WS echo + REST append)
    }

    final idx = conversations.indexWhere((c) => c.id == conversationId);
    if (idx >= 0) {
      final conv = conversations[idx];
      final isMine = message.senderId == user?.id;
      final isActive = _activeConversation == conversationId;
      if (isActive && !isMine) {
        channel.send({'type': 'read', 'conversationId': conversationId});
      }
      conversations[idx] = conv.copyWith(
        lastMessage: message,
        unread: isActive || isMine ? 0 : conv.unread + 1,
      );
      if (!isMine && !isActive && call == null && !conv.muted) {
        final title = conv.title;
        final body = conv.isGroup
            ? '${message.senderName ?? conv.memberName(message.senderId) ?? ''}: ${_messagePreview(message)}'
            : _messagePreview(message);
        if (Platform.isWindows) {
          // Hidden in the tray: surface as a Windows toast only (the in-app
          // banner is invisible behind a hidden window). If the window is
          // open the in-app banner handles it.
          unawaited(_maybeWindowsMessage(title, body));
        } else {
          NotificationService.showMessage(title: title, body: body);
          if (Platform.isAndroid && OsNotifications.instance.inBackground) {
            unawaited(
              OsNotifications.instance.showMessage(title: title, body: body),
            );
          }
        }
      }
    } else {
      refreshConversations();
    }
    list.add(message);
    notifyListeners();
  }

  /// Windows surfacing for a message: toast-only while the window is hidden
  /// in the tray (the in-app banner would be invisible anyway), in-app banner
  /// when the window is open.
  Future<void> _maybeWindowsMessage(String title, String body) async {
    if (!await TrayService.instance.isWindowVisible()) {
      await OsNotifications.instance.showMessage(title: title, body: body);
    } else {
      NotificationService.showMessage(title: title, body: body);
    }
  }

  /// Windows incoming-call toast, mirroring the full-screen Android route while
  /// the window is hidden in the tray.
  Future<void> _maybeWindowsCallToast(
    String peerId,
    String displayName,
    bool video,
  ) async {
    if (await TrayService.instance.isWindowVisible()) return;
    await OsNotifications.instance.showCall(
      peerId: peerId,
      displayName: displayName,
      video: video,
    );
  }

  String _messagePreview(Message m) {
    return switch (m.kind) {
      MessageKind.file => L.t('File: ${m.body}', ru: 'Файл: ${m.body}'),
      MessageKind.game => L.t('🎮 Minigame', ru: '🎮 Мини-игра'),
      _ => m.deleted ? L.t('Message deleted', ru: 'Сообщение удалено') : m.body,
    };
  }

  /// Applies a server-supplied message change (edit/delete/pin/reaction) to the
  /// local message list and the conversation preview in place.
  void _applyMessageUpdate(String conversationId, Message message) {
    final list = _messages[conversationId];
    if (list == null) {
      // Chat not loaded: nothing visible to patch, but the conversations
      // preview may need updating.
      unawaited(refreshConversations());
      return;
    }
    final idx = list.indexWhere((m) => m.id == message.id);
    if (idx >= 0) {
      list[idx] = message;
      final ci = conversations.indexWhere((c) => c.id == conversationId);
      if (ci >= 0 && conversations[ci].lastMessage?.id == message.id) {
        conversations[ci] = conversations[ci].copyWith(lastMessage: message);
      }
    }
    final pins = _pinned[conversationId];
    if (pins != null) {
      final pinIdx = pins.indexWhere((m) => m.id == message.id);
      if (message.pinned) {
        if (pinIdx >= 0) {
          pins[pinIdx] = message;
        } else {
          pins.insert(0, message);
        }
      } else if (pinIdx >= 0) {
        pins.removeAt(pinIdx);
      }
    }
    notifyListeners();
  }

  Future<void> loadPinned(String conversationId) async {
    final t = token;
    if (t == null) return;
    try {
      final list = await Api.pinnedMessages(t, conversationId);
      _pinned[conversationId] = list;
      notifyListeners();
    } on ApiException {
      // Pinned list is best-effort UI; failures are silent.
    }
  }

  List<Message> pinnedMessages(String conversationId) =>
      _pinned[conversationId] ?? const <Message>[];

  /// Marks the conversation currently open on screen; used to suppress
  /// message banners while the user is reading that chat.
  void setActiveConversation(String? conversationId) {
    _activeConversation = conversationId;
  }

  void _onTyping(Map<String, dynamic> event) {
    final convId = event['conversationId'] as String?;
    final userId = event['userId'] as String?;
    if (convId == null || userId == null || userId == user?.id) return;
    _typing.putIfAbsent(convId, () => <String>{}).add(userId);
    _typingTimers[convId]?.cancel();
    _typingTimers[convId] = Timer(const Duration(seconds: 3), () {
      _typing[convId]!.remove(userId);
      notifyListeners();
    });
    notifyListeners();
  }

  void _onFileSending(Map<String, dynamic> event) {
    final convId = event['conversationId'] as String?;
    final name = event['name'] as String?;
    if (convId == null || name == null) return;
    _fileSendingTimers[convId]?.cancel();
    _fileSending[convId] = name;
    _fileSendingUsers[convId] = event['userId'] as String? ?? '';
    _fileSendingTimers[convId] = Timer(const Duration(seconds: 30), () {
      _fileSending.remove(convId);
      _fileSendingUsers.remove(convId);
      notifyListeners();
    });
    notifyListeners();
  }

  void _onReadEvent(Map<String, dynamic> event) {
    final convId = event['conversationId'] as String?;
    if (convId == null) return;
    final list = _messages[convId];
    if (list == null) return;
    final now = DateTime.now();
    for (var i = 0; i < list.length; i++) {
      if (list[i].senderId == user?.id && list[i].readAt == null) {
        list[i] = list[i].copyWith(readAt: now);
      }
    }
    notifyListeners();
  }

  Future<void> refreshConversations() async {
    final t = token;
    if (t == null) return;
    try {
      final list = await Api.conversations(t);
      conversations
        ..clear()
        ..addAll(list);
      conversationsLoaded = true;
      notifyListeners();
    } on ApiException catch (e) {
      showSnack(e.message);
    }
  }

  Future<void> refreshBlocks() async {
    final t = token;
    if (t == null) return;
    try {
      final ids = await Api.blocks(t);
      blockedIds
        ..clear()
        ..addAll(ids);
      notifyListeners();
    } on ApiException catch (e) {
      showSnack(e.message);
    }
  }

  Future<void> blockUser(User peer) async {
    final t = token;
    if (t == null) return;
    try {
      await Api.setBlock(t, peer.id, blocked: true);
      blockedIds.add(peer.id);
      notifyListeners();
      showSnack(
        L.t(
          '${peer.displayName} blocked',
          ru: '${peer.displayName} заблокирован(а)',
        ),
      );
    } on ApiException catch (e) {
      showSnack(e.message);
    }
  }

  Future<void> unblockUser(User peer) async {
    final t = token;
    if (t == null) return;
    try {
      await Api.setBlock(t, peer.id, blocked: false);
      blockedIds.remove(peer.id);
      notifyListeners();
      showSnack(
        L.t(
          '${peer.displayName} unblocked',
          ru: '${peer.displayName} разблокирован(а)',
        ),
      );
    } on ApiException catch (e) {
      showSnack(e.message);
    }
  }

  Future<void> reportUser(User peer, {String reason = ''}) async {
    final t = token;
    if (t == null) return;
    try {
      await Api.reportUser(t, peer.id, reason: reason);
      showSnack(
        L.t(
          'Report submitted. Thanks for keeping Commsuite safe.',
          ru: 'Жалоба отправлена. Спасибо, что помогаете сохранять Commsuite в безопасности.',
        ),
      );
    } on ApiException catch (e) {
      showSnack(e.message);
    }
  }

  Future<void> updateBio(String bio) async {
    final t = token;
    if (t == null) return;
    try {
      user = await Api.setBio(t, bio);
      notifyListeners();
      showSnack(L.t('Bio updated', ru: 'Описание обновлено'));
    } on ApiException catch (e) {
      showSnack(e.message);
    }
  }

  Future<void> clearChat(Conversation conversation) async {
    final t = token;
    if (t == null) return;
    try {
      await Api.clearMessages(t, conversation.id);
      _messages.remove(conversation.id);
      _pinned.remove(conversation.id);
      final idx = conversations.indexWhere((c) => c.id == conversation.id);
      if (idx >= 0) {
        conversations[idx] = conversations[idx].copyWith(
          lastMessage: null,
          unread: 0,
        );
      }
      notifyListeners();
      showSnack(L.t('Chat cleared', ru: 'Чат очищен'));
    } on ApiException catch (e) {
      showSnack(e.message);
    }
  }

  void _replaceConversation(Conversation c) {
    final idx = conversations.indexWhere((x) => x.id == c.id);
    if (idx >= 0) {
      conversations[idx] = c;
    } else {
      conversations.add(c);
    }
    notifyListeners();
  }

  /// Drops a conversation locally (the group was left or deleted).
  void _removeConversation(String id) {
    conversations.removeWhere((x) => x.id == id);
    _messages.remove(id);
    _pinned.remove(id);
    notifyListeners();
  }

  Future<Conversation?> createGroup({
    required String name,
    String description = '',
    required List<String> memberIds,
  }) async {
    final t = token;
    if (t == null) return null;
    try {
      final conv = await Api.createGroup(
        t,
        name: name,
        description: description,
        memberIds: memberIds,
      );
      _replaceConversation(conv);
      return conv;
    } on ApiException catch (e) {
      showSnack(e.message);
      return null;
    }
  }

  Future<Conversation?> updateGroup(
    Conversation conv, {
    String? name,
    String? description,
  }) async {
    final t = token;
    if (t == null) return null;
    try {
      final updated = await Api.updateGroup(
        t,
        conv.id,
        name: name,
        description: description,
      );
      _replaceConversation(updated);
      return updated;
    } on ApiException catch (e) {
      showSnack(e.message);
      return null;
    }
  }

  Future<Conversation?> addGroupMember(Conversation conv, String userId) async {
    final t = token;
    if (t == null) return null;
    try {
      final updated = await Api.addGroupMember(t, conv.id, userId);
      _replaceConversation(updated);
      return updated;
    } on ApiException catch (e) {
      showSnack(e.message);
      return null;
    }
  }

  Future<void> removeGroupMember(Conversation conv, String userId) async {
    final t = token;
    if (t == null) return;
    try {
      final updated = await Api.removeGroupMember(t, conv.id, userId);
      if (updated == null) {
        _removeConversation(conv.id);
        showSnack(
          userId == user?.id
              ? L.t('You left the group', ru: 'Вы покинули группу')
              : L.t('Group deleted', ru: 'Группа удалена'),
        );
      } else {
        _replaceConversation(updated);
      }
    } on ApiException catch (e) {
      showSnack(e.message);
    }
  }

  Future<Conversation?> setGroupMemberRole(
    Conversation conv,
    String userId,
    String role,
  ) async {
    final t = token;
    if (t == null) return null;
    try {
      final updated = await Api.setGroupMemberRole(t, conv.id, userId, role);
      _replaceConversation(updated);
      return updated;
    } on ApiException catch (e) {
      showSnack(e.message);
      return null;
    }
  }

  Future<Conversation?> setGroupMuted(Conversation conv, bool muted) async {
    final t = token;
    if (t == null) return null;
    try {
      final updated = await Api.setGroupMute(t, conv.id, muted: muted);
      _replaceConversation(updated);
      return updated;
    } on ApiException catch (e) {
      showSnack(e.message);
      return null;
    }
  }

  Future<void> deleteGroup(Conversation conv) async {
    final t = token;
    if (t == null) return;
    try {
      await Api.deleteGroup(t, conv.id);
      _removeConversation(conv.id);
      showSnack(L.t('Group deleted', ru: 'Группа удалена'));
    } on ApiException catch (e) {
      showSnack(e.message);
    }
  }

  Conversation? conversationById(String id) {
    for (final c in conversations) {
      if (c.id == id) return c;
    }
    return null;
  }

  Future<Conversation?> openConversation(User peer) async {
    final t = token;
    if (t == null) return null;
    try {
      final conv = await Api.createConversation(t, peer.id);
      await loadMessages(conv.id);
      await refreshConversations();
      return conv;
    } on ApiException catch (e) {
      showSnack(e.message);
      return null;
    }
  }

  Future<void> loadMessages(String conversationId, {bool older = false}) async {
    final t = token;
    if (t == null) return;
    if (older && !_olderLoadsInFlight.add(conversationId)) return;
    final gen = (_messageLoadGen[conversationId] ?? 0) + 1;
    _messageLoadGen[conversationId] = gen;
    try {
      final existing = _messages[conversationId];
      final before = older && existing != null && existing.isNotEmpty
          ? existing.first.createdAt.millisecondsSinceEpoch
          : null;
      final batch = await Api.messages(t, conversationId, before: before);
      if (_messageLoadGen[conversationId] != gen) return;
      if (older) {
        if (batch.isEmpty) {
          _completedLoads.remove(conversationId);
          return;
        }
        _messages[conversationId] = [
          ...batch,
          ...(existing ?? const <Message>[]),
        ];
      } else {
        _messages[conversationId] = batch;
        if (batch.length >= _messagePageSize) {
          _completedLoads.add(conversationId);
        } else {
          _completedLoads.remove(conversationId);
        }
      }
      _activeConversation = conversationId;
      channel.send({'type': 'read', 'conversationId': conversationId});
      notifyListeners();
    } on ApiException catch (e) {
      showSnack(e.message);
    } finally {
      if (older) _olderLoadsInFlight.remove(conversationId);
    }
  }

  void sendTypingSignal(String conversationId) {
    channel.send({'type': 'typing', 'conversationId': conversationId});
  }

  Future<Message?> sendText(
    String conversationId,
    String body, {
    String? replyTo,
  }) async {
    final t = token;
    if (t == null || body.trim().isEmpty) return null;
    final conv = conversationById(conversationId);
    if (conv != null &&
        !conv.isGroup &&
        conv.peer != null &&
        isBlocked(conv.peer!.id)) {
      showSnack(
        L.t(
          'You blocked ${conv.peer!.displayName}. Unblock to send messages.',
          ru: 'Вы заблокировали ${conv.peer!.displayName}. Разблокируйте, чтобы отправлять сообщения.',
        ),
      );
      return null;
    }
    try {
      final message = await Api.sendMessage(
        t,
        conversationId,
        kind: 'text',
        body: body,
        replyTo: replyTo,
      );
      _appendLocal(conversationId, message);
      return message;
    } on ApiException catch (e) {
      showSnack(e.message);
      return null;
    }
  }

  Future<Message?> sendFile(
    String conversationId,
    String filePath,
    String filename,
  ) async {
    final t = token;
    if (t == null) return null;
    final conv = conversationById(conversationId);
    if (conv != null &&
        !conv.isGroup &&
        conv.peer != null &&
        isBlocked(conv.peer!.id)) {
      showSnack(
        L.t(
          'You blocked ${conv.peer!.displayName}. Unblock to send messages.',
          ru: 'Вы заблокировали ${conv.peer!.displayName}. Разблокируйте, чтобы отправлять сообщения.',
        ),
      );
      return null;
    }
    try {
      // Let the peer show "sending <filename>…" while the upload runs.
      channel.send({
        'type': 'file-sending',
        'conversationId': conversationId,
        'name': filename,
      });
      final attachment = await Api.uploadFile(t, filePath, filename: filename);
      final message = await Api.sendMessage(
        t,
        conversationId,
        kind: 'file',
        body: filename,
        attachmentId: attachment.id,
      );
      _fileSending.remove(conversationId);
      _fileSendingUsers.remove(conversationId);
      _fileSendingTimers[conversationId]?.cancel();
      _appendLocal(conversationId, message);
      return message;
    } on ApiException catch (e) {
      _fileSending.remove(conversationId);
      _fileSendingUsers.remove(conversationId);
      _fileSendingTimers[conversationId]?.cancel();
      showSnack(e.message);
      return null;
    }
  }

  void _appendLocal(String conversationId, Message message) {
    if (!_messages.containsKey(conversationId)) _messages[conversationId] = [];
    _messages[conversationId]!.add(message);
    final idx = conversations.indexWhere((c) => c.id == conversationId);
    if (idx >= 0) {
      conversations[idx] = conversations[idx].copyWith(
        lastMessage: message,
        unread: 0,
      );
    }
    notifyListeners();
  }

  Future<void> editMessage(
    String conversationId,
    Message message,
    String body,
  ) async {
    final t = token;
    if (t == null) return;
    final trimmed = body.trim();
    if (trimmed.isEmpty) return;
    try {
      final updated = await Api.editMessage(t, message.id, trimmed);
      _applyMessageUpdate(conversationId, updated);
    } on ApiException catch (e) {
      showSnack(e.message);
    }
  }

  Future<void> deleteMessage(String conversationId, Message message) async {
    final t = token;
    if (t == null) return;
    try {
      final updated = await Api.deleteMessage(t, message.id);
      _applyMessageUpdate(conversationId, updated);
    } on ApiException catch (e) {
      showSnack(e.message);
    }
  }

  Future<void> forwardMessage(
    Message message,
    String targetConversationId,
  ) async {
    final t = token;
    if (t == null) return;
    try {
      final sent = await Api.forwardMessage(
        t,
        message.id,
        targetConversationId,
      );
      _appendLocal(targetConversationId, sent);
    } on ApiException catch (e) {
      showSnack(e.message);
    }
  }

  Future<void> setMessagePinned(
    String conversationId,
    Message message,
    bool pinned,
  ) async {
    final t = token;
    if (t == null) return;
    try {
      final updated = await Api.setMessagePinned(t, message.id, pinned: pinned);
      _applyMessageUpdate(conversationId, updated);
    } on ApiException catch (e) {
      showSnack(e.message);
    }
  }

  Future<void> toggleReaction(
    String conversationId,
    Message message,
    String emoji,
  ) async {
    final t = token;
    if (t == null || user == null) return;
    try {
      final updated = await Api.setReaction(t, message.id, emoji);
      _applyMessageUpdate(conversationId, updated);
    } on ApiException catch (e) {
      showSnack(e.message);
    }
  }

  bool hasMoreMessages(String conversationId) =>
      _completedLoads.contains(conversationId);

  Future<bool> startCall(User peer, {required bool video}) async {
    if (call != null) return false;
    if (isBlocked(peer.id)) {
      showSnack(
        L.t(
          'You blocked ${peer.displayName}. Unblock to call.',
          ru: 'Вы заблокировали ${peer.displayName}. Разблокируйте, чтобы совершать звонки.',
        ),
      );
      return false;
    }
    if (!socketConnected) {
      showSnack(
        L.t(
          'Server not connected yet — wait a moment and try again.',
          ru: 'Сервер ещё не подключён — подождите немного и попробуйте снова.',
        ),
      );
      return false;
    }
    final ok = await webrtc.startLocal(video: video);
    if (!ok) {
      showSnack(
        L.t(
          'Could not start ${video ? 'video' : 'call'} (permissions or device missing).',
          ru: 'Не удалось запустить ${video ? 'видеозвонок' : 'звонок'} (нет разрешений или устройства).',
        ),
      );
      return false;
    }
    final session = CallSession(
      callId: _newCallId(),
      peer: peer,
      video: video,
      outgoing: true,
      phase: CallPhase.outgoing,
    );
    call = session;
    notifyListeners();
    _sendSignal(peer.id, 'call-invite', {
      'callId': session.callId,
      'video': video,
    });
    // Caller-side no-answer timeout: an outgoing call must not show
    // "Ringing..." forever (a callee that is frozen, backgrounded or missed
    // the notification would otherwise strand the caller indefinitely).
    _ringTimer?.cancel();
    _ringTimer = Timer(const Duration(seconds: 45), () {
      final active = call;
      if (active != null &&
          active.outgoing &&
          active.phase == CallPhase.outgoing &&
          active.peer.id == peer.id) {
        unawaited(
          _finalizeCall(
            reason: L.t(
              '${peer.displayName} did not answer',
              ru: '${peer.displayName} не ответил(а)',
            ),
          ),
        );
      }
    });
    return true;
  }

  Future<void> acceptCall() async {
    _ringTimer?.cancel();
    NotificationService.hideCall();
    _hideCallSurfaces();
    // Fully release the ring/ding players BEFORE touching the camera+mic:
    // a looping MediaPlayer being torn down during getUserMedia is a native
    // crash risk on Android (and this is where the phone dies "silently").
    await SoundPlayer.stopAndRelease();
    final s = call;
    if (s == null || s.outgoing) return;
    if (!socketConnected) {
      showSnack(
        L.t(
          'Server not connected yet — the call was declined.',
          ru: 'Сервер ещё не подключён — звонок был отклонён.',
        ),
      );
      await _finalizeCall();
      return;
    }
    final ok = await webrtc.startLocal(video: s.video);
    if (!ok) {
      await _finalizeCall();
      return;
    }
    s.phase = CallPhase.connecting;
    notifyListeners();
    // Push the call route on a LATER frame than the banner removal: mutating
    // the overlay (remove banner) and the route stack in the same frame made
    // the Windows build crash during layout ('RenderBox was not laid out').
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => WidgetsBinding.instance.addPostFrameCallback(
        (_) => CallScreen.push(),
      ),
    );
    await webrtc.createPeer(
      onSignal: (kind, payload) => _sendSignal(s.peer.id, kind, payload),
      onConnected: () => _markConnected(s),
      onDisconnected: () => _maybeEndSilently(s),
    );
    final offer = await webrtc.createOffer();
    if (offer != null) _sendSignal(s.peer.id, 'offer', offer.toMap());
  }

  Future<void> declineCall() async {
    NotificationService.hideCall();
    _hideCallSurfaces();
    final s = call;
    if (s == null || s.outgoing) return;
    _sendSignal(s.peer.id, 'call-decline', null);
    await _finalizeCall();
  }

  Future<void> hangUp() async {
    NotificationService.hideCall();
    _hideCallSurfaces();
    final s = call;
    if (s != null) _sendSignal(s.peer.id, 'call-hangup', null);
    await _finalizeCall();
  }

  void _markConnected(CallSession session) {
    _ringTimer?.cancel();
    NotificationService.hideCall();
    _hideCallSurfaces();
    session.phase = CallPhase.connected;
    notifyListeners();
  }

  void _maybeEndSilently(CallSession session) {
    if (call != null &&
        identical(call, session) &&
        session.phase != CallPhase.connected) {
      NotificationService.hideCall();
      _hideCallSurfaces();
      call = null;
      webrtc.stop();
      notifyListeners();
    }
  }

  Future<void> _handleSignal(
    Map<String, dynamic> from,
    String kind,
    Map<String, dynamic>? payload,
  ) async {
    final peer = User(
      id: from['id'] as String,
      username: from['username'] as String? ?? '',
      displayName: from['displayName'] as String? ?? '',
    );

    switch (kind) {
      case 'call-invite':
        if (call != null) {
          _sendSignal(peer.id, 'call-busy', null);
          return;
        }
        call = CallSession(
          callId: payload?['callId'] as String? ?? _newCallId(),
          peer: peer,
          video: payload?['video'] == true,
          outgoing: false,
          phase: CallPhase.incoming,
        );
        // A ringing incoming call must not ring forever (a missed/flaky
        // notification action or a frozen process would otherwise leave the
        // caller stuck in 'ringing'): auto-decline after the timeout.
        _ringTimer?.cancel();
        _ringTimer = Timer(const Duration(seconds: 30), () {
          final active = call;
          if (active != null &&
              !active.outgoing &&
              active.phase == CallPhase.incoming &&
              active.peer.id == peer.id) {
            declineCall();
          }
        });
        final hiddenInTray =
            Platform.isWindows && !await TrayService.instance.isWindowVisible();
        final inAppRing =
            !hiddenInTray &&
            !(Platform.isAndroid && OsNotifications.instance.inBackground);
        NotificationService.showCall(
          displayName: peer.displayName,
          video: call!.video,
          onAccept: acceptCall,
          onDecline: declineCall,
          ring: inAppRing,
        );
        if (Platform.isAndroid && OsNotifications.instance.inBackground) {
          // The overlay banner cannot be seen while the app is backgrounded:
          // mirror the incoming call into a heads-up/full-screen notification.
          OsNotifications.log(
            'call-invite: bg notif (lifecycle=${WidgetsBinding.instance.lifecycleState})',
          );
          unawaited(
            OsNotifications.instance.showCall(
              peerId: peer.id,
              displayName: peer.displayName,
              video: call!.video,
            ),
          );
        } else if (Platform.isWindows && hiddenInTray) {
          // Hidden in the tray: surface as a Windows call toast (its own
          // ringtone + Answer/Decline actions) instead of dragging the window
          // up. When the window is open the in-app banner above handles it.
          unawaited(
            _maybeWindowsCallToast(peer.id, peer.displayName, call!.video),
          );
        }
        notifyListeners();
        break;

      case 'call-busy':
      case 'call-decline':
        await _finalizeCall(
          reason: kind == 'call-busy'
              ? L.t(
                  '${peer.displayName} is on another call',
                  ru: '${peer.displayName} занят(а) на другом звонке',
                )
              : L.t(
                  '${peer.displayName} declined the call',
                  ru: '${peer.displayName} отклонил(а) звонок',
                ),
        );
        break;

      case 'offer':
        {
          final s = call;
          // If the invite's video flag was ever lost (old peer build), recover the
          // kind from the SDP so the UI shows "video call" instead of "audio call".
          final sdp = payload?['sdp'] as String? ?? '';
          if (s != null &&
              !s.outgoing &&
              !s.video &&
              sdp.contains('\nm=video ')) {
            s.video = true;
            notifyListeners();
          }
          await webrtc.createPeer(
            onSignal: (kind, payload) => _sendSignal(peer.id, kind, payload),
            onConnected: () {
              final active = call;
              if (active != null && active.peer.id == peer.id) {
                _markConnected(active);
              }
            },
            onDisconnected: () {
              final active = call;
              if (active != null && active.peer.id == peer.id) {
                _maybeEndSilently(active);
              }
            },
          );
          await webrtc.setRemoteOffer(payload ?? <String, dynamic>{});
          final answer = await webrtc.createAnswer();
          if (answer != null) _sendSignal(peer.id, 'answer', answer.toMap());
          if (s != null && s.outgoing && s.phase == CallPhase.outgoing) {
            s.phase = CallPhase.connecting;
            notifyListeners();
          }
          break;
        }

      case 'answer':
        {
          await webrtc.setRemoteAnswer(payload ?? <String, dynamic>{});
          final s = call;
          if (s != null && s.outgoing && s.phase == CallPhase.outgoing) {
            s.phase = CallPhase.connecting;
            notifyListeners();
          }
          break;
        }

      case 'ice':
        await webrtc.addRemoteIce(payload ?? <String, dynamic>{});
        break;

      case 'call-hangup':
        await _finalizeCall();
        break;
    }
  }

  void _sendSignal(String to, String kind, Map? payload) {
    channel.send({
      'type': 'signal',
      'to': to,
      'kind': kind,
      'payload': payload,
    });
  }

  /// Mirrors call state to the OS surfaces: dismisses the Android heads-up
  /// notification and drops the Windows window from the top of the z-order.
  void _hideCallSurfaces() {
    if (Platform.isAndroid) unawaited(OsNotifications.instance.cancelCall());
    if (Platform.isWindows) unawaited(TrayService.instance.releaseCallFocus());
  }

  Future<void> _finalizeCall({String? reason}) async {
    _ringTimer?.cancel();
    NotificationService.hideCall();
    _hideCallSurfaces();
    await SoundPlayer.stopAndRelease();
    call = null;
    await webrtc.stop();
    notifyListeners();
    if (reason != null) showSnack(reason);
  }

  String _newCallId() {
    final r = Random();
    return '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${r.nextInt(0xFFFFFF).toRadixString(36)}';
  }

  @override
  void dispose() {
    _authRetry?.cancel();
    _pingTimer?.cancel();
    _ringTimer?.cancel();
    channel.connected.removeListener(_onSocketConnectedChanged);
    SoundPlayer.stopAndRelease();
    for (final t in _typingTimers.values) {
      t.cancel();
    }
    for (final t in _fileSendingTimers.values) {
      t.cancel();
    }
    _fileSending.clear();
    _fileSendingUsers.clear();
    _sub?.cancel();
    channel.dispose();
    super.dispose();
  }
}
