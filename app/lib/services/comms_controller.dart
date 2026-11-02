import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/account.dart';
import '../core/app_config.dart';
import '../core/realtime.dart';
import '../models.dart';
import '../screens/call/call_screen.dart';
import 'broadcast_service.dart';
import 'notification_service.dart';
import 'os_notifications.dart';
import 'server_discovery.dart';
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

  // ---- live streaming -----------------------------------------------------
  /// Multi-peer media for the broadcast we host or watch. Signalling travels
  /// over the websocket; media is forced through the TURN relay.
  final BroadcastService broadcast = BroadcastService();

  /// The saved channel profile on the Stream tab.
  StreamChannel? streamChannel;
  List<StreamInfo> streamDirectory = [];
  List<String> streamGames = [];

  /// Our own live broadcast, as the broadcaster sees it.
  StreamInfo? myStream;

  /// The broadcast we are watching, as a viewer.
  StreamInfo? watching;

  List<StreamViewer> streamViewers = [];
  List<User> streamMods = [];
  List<User> streamBans = [];

  /// Conversation id of the broadcast we host or watch (the dedicated chat).
  String? streamChatId;
  bool streamLoading = false;

  bool get streaming => myStream != null || watching != null;

  StreamSubscription? _sub;
  final Map<String, Timer> _typingTimers = {};

  Timer? _pingTimer;
  Timer? _authRetry;
  Timer? _ringTimer;
  final GlobalKey<ScaffoldMessengerState> messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  bool get authed => user != null;
  bool conversationsLoaded = false;

  // ---- accounts -----------------------------------------------------------

  List<AccountRecord> get accounts => AppConfig.accounts;

  String? get activeAccountId => AppConfig.activeAccountId;

  AccountRecord? get activeAccount => AppConfig.activeAccount;

  /// Unread conversations across the account currently connected.
  int get unreadTotal => conversations.fold(0, (sum, c) => sum + c.unread);

  /// Unread for [id]: live for the active account, the value cached when it
  /// was last active (or fetched from its server) for the others.
  int unreadForAccount(String id) {
    if (id == AppConfig.activeAccountId && authed) return unreadTotal;
    return AppConfig.accountById(id)?.unread ?? 0;
  }

  /// Unread waiting in accounts other than the active one.
  int get otherAccountsUnread => accounts
      .where((a) => a.id != AppConfig.activeAccountId)
      .fold(0, (sum, a) => sum + unreadForAccount(a.id));

  /// The realtime socket has finished its handshake. Until the server responds
  /// (it can take 10-20 s after launch) calls must NOT touch WebRTC: setting up
  /// peer connections in that window aborts the native addTrack code on Android.
  bool get socketConnected => channel.connected.value;

  /// A saved (remembered) session exists but the user isn't authenticated yet:
  /// the app is (re)connecting to the saved server in the background. The UI
  /// shows the "redirecting to your server" screen while this is true.
  bool get serverConnecting => token != null && user == null;

  /// Leaves the saved session alone but returns to the plain login screen (the
  /// account stays available in the switcher).
  void startFreshSession() {
    _authRetry?.cancel();
    unawaited(_finalizeCall());
    unawaited(_teardownStream());
    channel.disconnect();
    _resetLocalState();
    token = null;
    user = null;
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
    _bindBroadcast();
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
        await AppConfig.adoptLegacyToken(me, t);
        channel.connect(AppConfig.wsUrlWithToken(t));
        unawaited(refreshBlocks());
        unawaited(refreshConversations());
        unawaited(refreshAccountUnread());
        notifyListeners();
      } on ApiException catch (e) {
        if (e.status == 401) {
          await _dropActiveAccount(); // token no longer valid
          notifyListeners();
          return;
        }
        // The saved address may have gone stale (random CloudPub subdomain):
        // try to learn the current one before the next retry.
        ServerDiscovery.instance.start();
        _autoconnect(); // server unreachable yet: keep the token and retry
      } catch (_) {
        ServerDiscovery.instance.start();
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
      await _applyAuth(res.token, res.user);
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
      await _applyAuth(res.token, res.user);
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

  Future<void> _applyAuth(String newToken, User newUser) async {
    _authRetry?.cancel();
    await _finalizeCall();
    await _teardownStream();
    channel.disconnect();
    _storeActiveUnread();
    _resetLocalState();
    token = newToken;
    user = newUser;
    await AppConfig.upsertAccount(
      AccountRecord.fromUser(
        newUser,
        serverUrl: AppConfig.serverUrl,
        token: newToken,
        remember: AppConfig.rememberMe,
      ),
    );
    L.setLang(await AppConfig.loadLanguage());
    channel.connect(AppConfig.wsUrlWithToken(newToken));
    unawaited(refreshBlocks());
    unawaited(refreshConversations());
    unawaited(refreshAccountUnread());
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
    if (authed) unawaited(refreshAccountUnread());
  }

  /// Signs out of the active account: removes it from this device and switches
  /// to the most recently used remaining account, if any.
  Future<void> logout() async {
    _authRetry?.cancel();
    await _finalizeCall();
    await _teardownStream();
    channel.disconnect();
    _storeActiveUnread();
    _resetLocalState();
    await _dropActiveAccount();
    notifyListeners();
  }

  /// Removes [id]. Signing out of the active account switches to the next one.
  Future<void> removeAccount(String id) async {
    if (id == AppConfig.activeAccountId) {
      await logout();
      return;
    }
    await AppConfig.removeAccount(id);
    notifyListeners();
  }

  /// Switches to a saved account without asking for a password.
  Future<void> switchAccount(String id) async {
    if (id == AppConfig.activeAccountId && authed) return;
    final account = AppConfig.accountById(id);
    if (account == null) return;
    _authRetry?.cancel();
    await _finalizeCall();
    await _teardownStream();
    channel.disconnect();
    _storeActiveUnread();
    _resetLocalState();
    await AppConfig.activateAccount(id);
    L.setLang(await AppConfig.loadLanguage());
    token = account.token;
    user = null;
    notifyListeners();
    _autoconnect();
    unawaited(refreshAccountUnread());
  }

  /// Drops the active account (invalid token or explicit sign-out) and moves
  /// to the next saved account, or to the login screen when none are left.
  Future<void> _dropActiveAccount() async {
    _resetLocalState();
    final id = AppConfig.activeAccountId;
    if (id != null) await AppConfig.removeAccount(id);
    final next = AppConfig.activeAccount;
    if (next == null) {
      await _clearAuth();
      return;
    }
    L.setLang(await AppConfig.loadLanguage());
    token = next.token;
    user = null;
    _autoconnect();
  }

  Future<void> _clearAuth() async {
    token = null;
    user = null;
    await AppConfig.clearToken();
  }

  void _storeActiveUnread() {
    final id = AppConfig.activeAccountId;
    if (id == null) return;
    unawaited(AppConfig.setAccountUnread(id, unreadTotal));
  }

  /// Fetches unread counts for the inactive accounts so the switcher can show
  /// real badges without keeping a socket open for every account.
  Future<void> refreshAccountUnread() async {
    var changed = false;
    for (final account in AppConfig.accounts) {
      if (account.id == AppConfig.activeAccountId) continue;
      if (account.token.isEmpty) continue;
      try {
        final list = await Api.conversations(
          account.token,
          baseUrl: '${account.serverUrl}/api',
        );
        final unread = list.fold<int>(0, (sum, c) => sum + c.unread);
        if (account.unread != unread) changed = true;
        await AppConfig.setAccountUnread(account.id, unread);
      } catch (_) {
        // Offline account: keep the last known badge.
      }
    }
    if (changed) notifyListeners();
  }

  void _resetLocalState() {
    conversations.clear();
    _messages.clear();
    _pinned.clear();
    _activeGames.clear();
    _typing.clear();
    for (final t in _typingTimers.values) {
      t.cancel();
    }
    _typingTimers.clear();
    _fileSending.clear();
    _fileSendingUsers.clear();
    for (final t in _fileSendingTimers.values) {
      t.cancel();
    }
    _fileSendingTimers.clear();
    onlineIds.clear();
    blockedIds.clear();
    _completedLoads.clear();
    _olderLoadsInFlight.clear();
    _messageLoadGen.clear();
    _activeConversation = null;
    conversationsLoaded = false;
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

      case 'stream-viewer-joined':
        unawaited(_onStreamViewerJoined(event));
        break;

      case 'stream-viewer-left':
        unawaited(_onStreamViewerLeft(event));
        break;

      case 'stream-ended':
        unawaited(_onStreamEnded(event));
        break;

      case 'stream-kicked':
        unawaited(_onStreamKicked(event));
        break;

      case 'stream-updated':
        unawaited(_onStreamUpdated(event));
        break;

      case 'stream-modded':
        _onStreamModChanged(event, added: true);
        break;

      case 'stream-unmodded':
        _onStreamModChanged(event, added: false);
        break;

      case 'stream-signal':
        unawaited(_onStreamSignalEvent(event));
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
    bool video, {
    String? title,
  }) async {
    if (await TrayService.instance.isWindowVisible()) return;
    await OsNotifications.instance.showCall(
      peerId: peerId,
      displayName: displayName,
      video: video,
      title: title,
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
      _typing[convId]?.remove(userId);
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

  /// Opens the support ticket conversation, inviting all moderators.
  Future<Conversation?> requestSupport({
    String subject = '',
    required String message,
  }) async {
    final t = token;
    if (t == null) return null;
    try {
      final conv = await Api.requestSupport(
        t,
        subject: subject,
        message: message,
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

  /// Deterministic perfect-negotiation role: when both ends offer at once,
  //  exactly one (the peer with the smaller id) is "polite" and yields. Both
  //  ends compute the same answer from the two user ids, so they never both
  //  yield or both keep their offer.
  bool _isPolite(String peerId) => (user?.id ?? '').compareTo(peerId) < 0;

  Future<bool> startCall(User peer, {required bool video}) async {
    if (call != null || streaming) return false;
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
      polite: _isPolite(s.peer.id),
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
        if (call != null || streaming) {
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
            polite: _isPolite(peer.id),
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

  // ---- live streaming -----------------------------------------------------

  /// Wires the shared media service to the websocket. Called once at boot.
  void _bindBroadcast() {
    broadcast.onSignal = (to, kind, payload) {
      final id = myStream?.id ?? watching?.id;
      if (id == null) return;
      channel.send({
        'type': 'stream-signal',
        'streamId': id,
        'to': to,
        'kind': kind,
        'payload': payload,
      });
    };
    broadcast.onViewerConnected = (_) => unawaited(refreshStreamViewers());
    broadcast.onViewerDisconnected = (_) => unawaited(refreshStreamViewers());
    broadcast.onRemoteStream = notifyListeners;
  }

  /// Loads the Stream tab: my channel profile, the live directory and the game
  /// autocomplete list. Also recovers a broadcast that outlived an app restart.
  Future<void> refreshStreamTab() async {
    final t = token;
    if (t == null) return;
    streamLoading = true;
    notifyListeners();
    try {
      final mine = await Api.myStream(t);
      streamChannel = mine.channel;
      if (mine.live != null) {
        myStream ??= mine.live;
        streamChatId ??= mine.live!.chatId;
      }
      streamDirectory = await Api.streams(t);
      streamGames = await Api.streamGames(t);
      if (myStream != null) await _refreshStreamManagement();
    } on ApiException catch (e) {
      showSnack(e.message);
    } finally {
      streamLoading = false;
      notifyListeners();
    }
  }

  Future<bool> saveStreamChannel({
    String? title,
    String? description,
    String? game,
    String? visibility,
    int? slowMode,
  }) async {
    final t = token;
    if (t == null) return false;
    try {
      final saved = await Api.saveStreamChannel(
        t,
        title: title,
        description: description,
        game: game,
        visibility: visibility,
        slowMode: slowMode,
      );
      streamChannel = saved.channel;
      if (saved.live != null) myStream = saved.live;
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      showSnack(e.message);
      return false;
    }
  }

  /// Starts hosting a broadcast. The caller pushes the broadcast screen.
  Future<bool> goLive({String quality = '720p'}) async {
    if (streaming) return false;
    if (call != null) {
      showSnack(
        L.t(
          'Finish the current call before going live.',
          ru: 'Сначала завершите текущий звонок.',
        ),
      );
      return false;
    }
    final t = token;
    if (t == null || !socketConnected) {
      showSnack(
        L.t(
          'Server not connected yet — wait a moment and try again.',
          ru: 'Сервер ещё не подключён — подождите немного и попробуйте снова.',
        ),
      );
      return false;
    }
    // Media is relay-only by design: refuse rather than silently going
    // peer-to-peer when the server has no TURN configuration.
    final ice = await AppConfig.fetchIceConfig();
    if (ice['iceTransportPolicy'] != 'relay') {
      showSnack(
        L.t(
          'Live streaming needs the server TURN relay. Configure it in server settings.',
          ru: 'Для трансляций нужен TURN-сервер. Настройте его на сервере.',
        ),
      );
      return false;
    }
    final ok = await broadcast.startBroadcast(quality: quality);
    if (!ok) {
      showSnack(
        L.t(
          'Could not start the camera (permissions or device missing).',
          ru: 'Не удалось запустить камеру (нет разрешений или устройства).',
        ),
      );
      return false;
    }
    try {
      final launch = await Api.goLive(t);
      myStream = launch.stream;
      streamChatId = launch.chatId;
      streamViewers = [];
      streamMods = [];
      streamBans = [];
      notifyListeners();
      unawaited(refreshConversations());
      unawaited(_refreshStreamManagement());
      return true;
    } on ApiException catch (e) {
      await broadcast.stop();
      showSnack(e.message);
      return false;
    }
  }

  Future<void> endMyStream({String? reason}) async {
    final s = myStream;
    final t = token;
    if (s != null && t != null) {
      try {
        await Api.endStream(t, s.id);
      } on ApiException {
        // Already closed server-side; still tear down locally.
      }
    }
    await _teardownStream(reason: reason);
    unawaited(refreshConversations());
  }

  /// Joins [info] as a viewer. The caller pushes the watch screen.
  Future<bool> joinStream(StreamInfo info) async {
    if (streaming) return false;
    if (call != null) {
      showSnack(
        L.t(
          'Finish the current call before watching a stream.',
          ru: 'Сначала завершите текущий звонок.',
        ),
      );
      return false;
    }
    final t = token;
    if (t == null || !socketConnected) {
      showSnack(
        L.t(
          'Server not connected yet — wait a moment and try again.',
          ru: 'Сервер ещё не подключён — подождите немного и попробуйте снова.',
        ),
      );
      return false;
    }
    final ice = await AppConfig.fetchIceConfig();
    if (ice['iceTransportPolicy'] != 'relay') {
      showSnack(
        L.t(
          'Live streaming needs the server TURN relay.',
          ru: 'Для трансляций нужен TURN-сервер.',
        ),
      );
      return false;
    }
    try {
      final launch = await Api.joinStream(t, info.id);
      watching = launch.stream;
      streamChatId = launch.chatId;
      await broadcast.prepareWatching();
      unawaited(refreshConversations());
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      showSnack(e.message);
      return false;
    }
  }

  Future<void> leaveWatching({String? reason}) async {
    final s = watching;
    final t = token;
    if (s != null && t != null) {
      try {
        await Api.leaveStream(t, s.id);
      } on ApiException {
        // The stream may already be over.
      }
    }
    await _teardownStream(reason: reason);
  }

  Future<void> _teardownStream({String? reason}) async {
    final wasBroadcasting = myStream != null;
    myStream = null;
    watching = null;
    streamChatId = null;
    streamViewers = [];
    streamMods = [];
    streamBans = [];
    await broadcast.stop();
    notifyListeners();
    if (wasBroadcasting) unawaited(refreshConversations());
    if (reason != null) showSnack(reason);
  }

  Future<void> _refreshStreamManagement() async {
    final s = myStream;
    final t = token;
    if (s == null || t == null) return;
    try {
      streamViewers = await Api.streamViewers(t, s.id);
      streamMods = await Api.streamMods(t, s.id);
      streamBans = await Api.streamBans(t, s.id);
      myStream = s.copyWith(viewerCount: streamViewers.length);
      notifyListeners();
    } on ApiException {
      // The broadcast may have just ended; the screen closes on its own.
    }
  }

  Future<void> refreshStreamViewers() async {
    final s = myStream;
    final t = token;
    if (s == null || t == null) return;
    try {
      final viewers = await Api.streamViewers(t, s.id);
      streamViewers = viewers;
      myStream = s.copyWith(viewerCount: viewers.length);
      notifyListeners();
    } on ApiException {
      // ignore: transient
    }
  }

  /// Viewer list for any stream we are allowed to moderate (broadcaster or a
  /// channel mod watching someone else's broadcast).
  Future<List<StreamViewer>> fetchStreamViewers(String streamId) async {
    final t = token;
    if (t == null) return const [];
    try {
      return await Api.streamViewers(t, streamId);
    } on ApiException catch (e) {
      showSnack(e.message);
      return const [];
    }
  }

  Future<List<User>> fetchStreamBans(String streamId) async {
    final t = token;
    if (t == null) return const [];
    try {
      return await Api.streamBans(t, streamId);
    } on ApiException catch (e) {
      showSnack(e.message);
      return const [];
    }
  }

  Future<void> kickStreamViewer(String streamId, String userId) async {
    final t = token;
    if (t == null) return;
    try {
      await Api.kickStreamViewer(t, streamId, userId);
      if (myStream?.id == streamId) await broadcast.removeViewer(userId);
      await refreshStreamViewers();
    } on ApiException catch (e) {
      showSnack(e.message);
    }
  }

  Future<void> banStreamViewer(String streamId, String userId) async {
    final t = token;
    if (t == null) return;
    try {
      await Api.banStreamViewer(t, streamId, userId);
      if (myStream?.id == streamId) await broadcast.removeViewer(userId);
      await _refreshStreamManagement();
    } on ApiException catch (e) {
      showSnack(e.message);
    }
  }

  Future<void> unbanStreamViewer(String streamId, String userId) async {
    final t = token;
    if (t == null) return;
    try {
      await Api.unbanStreamViewer(t, streamId, userId);
      await _refreshStreamManagement();
    } on ApiException catch (e) {
      showSnack(e.message);
    }
  }

  Future<void> kickViewer(String userId) async {
    final s = myStream;
    final t = token;
    if (s == null || t == null) return;
    try {
      await Api.kickStreamViewer(t, s.id, userId);
      await broadcast.removeViewer(userId);
      await refreshStreamViewers();
    } on ApiException catch (e) {
      showSnack(e.message);
    }
  }

  Future<void> banViewer(String userId) async {
    final s = myStream;
    final t = token;
    if (s == null || t == null) return;
    try {
      await Api.banStreamViewer(t, s.id, userId);
      await broadcast.removeViewer(userId);
      await _refreshStreamManagement();
    } on ApiException catch (e) {
      showSnack(e.message);
    }
  }

  Future<void> unbanViewer(String userId) async {
    final s = myStream;
    final t = token;
    if (s == null || t == null) return;
    try {
      await Api.unbanStreamViewer(t, s.id, userId);
      await _refreshStreamManagement();
    } on ApiException catch (e) {
      showSnack(e.message);
    }
  }

  Future<void> appointStreamMod(User user) async {
    final s = myStream;
    final t = token;
    if (s == null || t == null) return;
    try {
      await Api.addStreamMod(t, s.id, user.id);
      await _refreshStreamManagement();
    } on ApiException catch (e) {
      showSnack(e.message);
    }
  }

  Future<void> removeStreamMod(User user) async {
    final s = myStream;
    final t = token;
    if (s == null || t == null) return;
    try {
      await Api.removeStreamMod(t, s.id, user.id);
      await _refreshStreamManagement();
    } on ApiException catch (e) {
      showSnack(e.message);
    }
  }

  Future<void> setStreamSlowMode(int seconds) async {
    await saveStreamChannel(slowMode: seconds);
  }

  String get streamQuality => broadcast.quality;

  /// Switches the capture preset while live. Tracks are hot-swapped on every
  /// viewer connection, so nobody has to re-join.
  Future<void> setStreamQuality(String quality) async {
    final ok = await broadcast.setQuality(quality);
    if (!ok) {
      showSnack(
        L.t(
          'Could not switch the stream quality.',
          ru: 'Не удалось сменить качество трансляции.',
        ),
      );
    }
    notifyListeners();
  }

  /// Loads the dedicated conversation of the current broadcast for the chat UI.
  Future<Conversation?> openStreamChat() async {
    final t = token;
    final id = streamChatId;
    if (t == null || id == null) return null;
    try {
      return await Api.conversation(t, id);
    } on ApiException catch (e) {
      showSnack(e.message);
      return null;
    }
  }

  // ---- broadcast events ---------------------------------------------------

  Future<void> _onStreamViewerJoined(Map<String, dynamic> event) async {
    final s = myStream;
    if (s == null || event['streamId'] != s.id) return;
    final viewer = event['viewer'] is Map
        ? User.fromJson(Map<String, dynamic>.from(event['viewer'] as Map))
        : null;
    if (viewer == null) return;
    myStream = s.copyWith(
      viewerCount: (event['viewerCount'] as num?)?.toInt() ?? s.viewerCount,
    );
    notifyListeners();
    await broadcast.addViewer(viewer.id);
    await refreshStreamViewers();
  }

  Future<void> _onStreamViewerLeft(Map<String, dynamic> event) async {
    final s = myStream;
    if (s == null || event['streamId'] != s.id) return;
    final userId = event['userId'] as String? ?? '';
    if (userId.isNotEmpty) await broadcast.removeViewer(userId);
    myStream = s.copyWith(
      viewerCount: (event['viewerCount'] as num?)?.toInt() ?? s.viewerCount,
    );
    notifyListeners();
    await refreshStreamViewers();
  }

  Future<void> _onStreamSignalEvent(Map<String, dynamic> event) async {
    if (!streaming) return;
    final id = myStream?.id ?? watching?.id;
    if (event['streamId'] != id) return;
    final from = event['from'] is Map
        ? Map<String, dynamic>.from(event['from'] as Map)
        : <String, dynamic>{};
    final fromId = from['id'] as String? ?? '';
    if (fromId.isEmpty) return;
    final payload = event['payload'] is Map
        ? Map<String, dynamic>.from(event['payload'] as Map)
        : <String, dynamic>{};
    await broadcast.handleSignal(
      fromId,
      event['kind'] as String? ?? '',
      payload,
    );
  }

  Future<void> _onStreamEnded(Map<String, dynamic> event) async {
    final id = event['streamId'] as String? ?? '';
    if (watching != null && watching!.id == id) {
      await _teardownStream(
        reason: L.t(
          'The live stream ended',
          ru: 'Трансляция завершилась',
        ),
      );
    } else if (myStream != null && myStream!.id == id) {
      await _teardownStream();
    }
    unawaited(refreshStreamTab());
  }

  Future<void> _onStreamKicked(Map<String, dynamic> event) async {
    final id = event['streamId'] as String? ?? '';
    final s = watching;
    if (s == null || s.id != id) return;
    final banned = event['reason'] == 'banned';
    await _teardownStream(
      reason: banned
          ? L.t(
              'You are banned from this channel',
              ru: 'Вы забанены на этом канале',
            )
          : L.t(
              'You were removed from the stream',
              ru: 'Вас удалили с трансляции',
            ),
    );
    unawaited(refreshStreamTab());
  }

  Future<void> _onStreamUpdated(Map<String, dynamic> event) async {
    if (event['stream'] is! Map) return;
    final updated = StreamInfo.fromJson(
      Map<String, dynamic>.from(event['stream'] as Map),
    );
    if (watching != null && watching!.id == updated.id) {
      watching = updated;
      notifyListeners();
    }
    unawaited(refreshStreamTab());
  }

  void _onStreamModChanged(Map<String, dynamic> event, {required bool added}) {
    final broadcasterId = event['broadcasterId'] as String? ?? '';
    final w = watching;
    if (w != null && broadcasterId.isNotEmpty && w.broadcaster.id == broadcasterId) {
      watching = w.copyWith(canManage: added, isMod: added);
      notifyListeners();
    }
    unawaited(refreshStreamTab());
    showSnack(
      added
          ? L.t(
              'You are now a moderator of this channel',
              ru: 'Вы теперь модератор этого канала',
            )
          : L.t(
              'You are no longer a moderator of this channel',
              ru: 'Вы больше не модератор этого канала',
            ),
    );
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
