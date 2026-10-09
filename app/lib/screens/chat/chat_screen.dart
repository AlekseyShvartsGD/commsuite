import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app.dart';
import '../../core/app_config.dart';
import '../../models.dart';
import '../../services/attachment_helper.dart';
import '../../services/comms_controller.dart';
import '../../services/file_service.dart';
import '../../services/url_service.dart';
import '../../services/virustotal.dart';
import '../../widgets/user_avatar.dart';
import '../browser/scan_result_dialog.dart';
import '../call/call_screen.dart';
import '../profile/profile_screen.dart';
import 'group_info_sheet.dart';
import '../../core/localizations.dart';

const _kReactionEmojis = [
  '👍',
  '❤️',
  '😂',
  '🤣',
  '🔥',
  '🎉',
  '😮',
  '😢',
  '😡',
  '👏',
  '🙏',
  '💯',
];

class ChatScreen extends StatefulWidget {
  final Conversation conversation;

  const ChatScreen({super.key, required this.conversation});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _guessInput = TextEditingController();
  final _scroll = ScrollController();
  DateTime _lastTyping = DateTime.fromMillisecondsSinceEpoch(0);
  bool _sending = false;
  PlatformFile? _pendingFile;
  int? _pendingFileSize;
  Message? _replyTo;
  Message? _editing;

  Conversation get conversation => widget.conversation;
  late final CommsController controller;

  /// Display name of the 1:1 peer (game panels and calls only exist in DMs).
  String get _peerName =>
      conversation.peer?.displayName ?? L.t('You', ru: 'Вы');

  @override
  void initState() {
    super.initState();
    controller = CommsScope.read(context);
    controller.loadMessages(conversation.id);
    controller.refreshActiveGame(conversation.id);
    controller.loadPinned(conversation.id);
  }

  @override
  void dispose() {
    // Use the captured controller: reading via an InheritedWidget here is not
    // allowed while the element is being unmounted (deactivated ancestor).
    controller.setActiveConversation(null);
    _input.dispose();
    _guessInput.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final controller = CommsScope.read(context);
    final file = _pendingFile;
    if (_sending || (file == null && _input.text.trim().isEmpty)) return;
    setState(() => _sending = true);
    if (file != null) {
      await controller.sendFile(conversation.id, file.path!, file.name);
    } else if (_editing != null) {
      final target = _editing!;
      final body = _input.text.trim();
      _input.clear();
      setState(() => _editing = null);
      await controller.editMessage(conversation.id, target, body);
    } else {
      final reply = _replyTo;
      final body = _input.text.trim();
      _input.clear();
      if (reply != null) setState(() => _replyTo = null);
      await controller.sendText(conversation.id, body, replyTo: reply?.id);
    }
    if (!mounted) return;
    setState(() {
      _sending = false;
      _pendingFile = null;
      _pendingFileSize = null;
    });
  }

  Future<void> _attach() async {
    final file = await FilePicker.pickFile();
    if (file == null) return;
    final size = await file.length();
    if (!mounted) return;
    setState(() {
      _pendingFile = file; // compose preview; sent via the send button
      _pendingFileSize = size;
      // Sending a file always sends a plain new message.
      _replyTo = null;
      _editing = null;
    });
  }

  void _onTyping() {
    final now = DateTime.now();
    if (now.difference(_lastTyping).inMilliseconds > 1200) {
      _lastTyping = now;
      CommsScope.read(context).sendTypingSignal(conversation.id);
    }
  }

  Future<void> _makeCall(bool video) async {
    final controller = CommsScope.read(context);
    final peer = conversation.peer;
    if (peer == null) return;
    final ok = await controller.startCall(peer, video: video);
    if (ok && mounted) {
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const CallScreen()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = CommsScope.of(context);
    final peer = conversation.peer;
    final isGroup = conversation.isGroup;
    final scheme = Theme.of(context).colorScheme;

    final String title;
    final String subtitle;
    TextStyle? subtitleStyle;
    if (isGroup) {
      title = conversation.title;
      subtitle = L.plural(
        conversation.members.length,
        enOne: '${conversation.members.length} member',
        enMany: '${conversation.members.length} members',
        ruOne: '${conversation.members.length} участник',
        ruFew: '${conversation.members.length} участника',
        ruMany: '${conversation.members.length} участников',
      );
      subtitleStyle = themeSubtitle(
        context,
        color: conversation.muted ? scheme.onSurfaceVariant : scheme.primary,
      );
    } else {
      title = peer?.displayName ?? '';
      final p = peer!;
      subtitle = controller.isBlocked(p.id)
          ? L.t('blocked', ru: 'заблокирован')
          : (controller.isOnline(p.id)
                ? L.t('online', ru: 'в сети')
                : L.t('offline', ru: 'не в сети'));
      subtitleStyle = controller.isBlocked(p.id)
          ? themeSubtitle(context, color: Colors.red)
          : themeSubtitle(context);
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            if (isGroup) {
              _showGroupInfo();
            } else {
              final p = conversation.peer;
              if (p == null) return;
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      ProfileScreen(peer: p, conversation: conversation),
                ),
              );
            }
          },
          child: Row(
            children: [
              UserAvatar(
                name: title,
                seed: isGroup ? conversation.id : (peer?.username ?? ''),
                showOnline:
                    !isGroup && peer != null && controller.isOnline(peer.id),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, overflow: TextOverflow.ellipsis),
                    Text(subtitle, style: subtitleStyle),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (isGroup)
            IconButton(
              tooltip: L.t('Group info', ru: 'Информация о группе'),
              icon: const Icon(Icons.people_outline),
              onPressed: _showGroupInfo,
            )
          else ...[
            IconButton(
              tooltip: L.t('Voice call', ru: 'Голосовой звонок'),
              icon: const Icon(Icons.call),
              onPressed: () => _makeCall(false),
            ),
            IconButton(
              tooltip: L.t('Video call', ru: 'Видеозвонок'),
              icon: const Icon(Icons.videocam),
              onPressed: () => _makeCall(true),
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _messageList(controller)),
          _gamePanel(controller),
          if (!isGroup && peer != null && controller.isBlocked(peer.id))
            _blockedBanner()
          else ...[
            _inputStatus(controller),
            if (_pendingFile != null) _pendingFileChip(),
            _inputBar(controller),
          ],
        ],
      ),
    );
  }

  TextStyle? themeSubtitle(BuildContext context, {Color? color}) {
    return Theme.of(context).textTheme.bodySmall?.copyWith(
      color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
    );
  }

  void _showGroupInfo() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => GroupInfoSheet(conversation: conversation),
    );
  }

  Future<void> _showMessageActions(Message message) async {
    if (message.deleted) {
      CommsScope.read(context)
          .showSnack(L.t('Message deleted', ru: 'Сообщение удалено'));
      return;
    }
    final me = CommsScope.read(context).user?.id;
    final mine = message.senderId == me;
    final canEdit = mine && message.kind == MessageKind.text;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  L.t('Message', ru: 'Сообщение'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              ListTile(
                leading: const Icon(Icons.add_reaction_outlined),
                title: Text(L.t('React', ru: 'Реакция')),
                onTap: () => Navigator.pop(context, 'react'),
              ),
              ListTile(
                leading: const Icon(Icons.reply),
                title: Text(L.t('Reply', ru: 'Ответить')),
                onTap: () => Navigator.pop(context, 'reply'),
              ),
              if (message.pinned)
                ListTile(
                  leading: const Icon(Icons.push_pin, color: Colors.orange),
                  title: Text(L.t('Unpin', ru: 'Открепить')),
                  onTap: () => Navigator.pop(context, 'unpin'),
                )
              else
                ListTile(
                  leading: const Icon(Icons.push_pin_outlined),
                  title: Text(L.t('Pin', ru: 'Закрепить')),
                  onTap: () => Navigator.pop(context, 'pin'),
                ),
              ListTile(
                leading: const Icon(Icons.forward),
                title: Text(L.t('Forward', ru: 'Переслать')),
                onTap: () => Navigator.pop(context, 'forward'),
              ),
              if (message.kind == MessageKind.text)
                ListTile(
                  leading: const Icon(Icons.content_copy),
                  title: Text(L.t('Copy text', ru: 'Копировать текст')),
                  onTap: () => Navigator.pop(context, 'copy'),
                ),
              if (message.kind == MessageKind.text &&
                  UrlService.findUrls(message.body).isNotEmpty)
                ListTile(
                  leading: const Icon(
                    Icons.shield_outlined,
                    color: Colors.orange,
                  ),
                  title: Text(
                    L.t(
                      'Scan link with VirusTotal',
                      ru: 'Сканировать ссылку через VirusTotal',
                    ),
                  ),
                  onTap: () => Navigator.pop(context, 'scan-link'),
                ),
              if (canEdit)
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: Text(L.t('Edit', ru: 'Изменить')),
                  onTap: () => Navigator.pop(context, 'edit'),
                ),
              if (mine)
                ListTile(
                  leading: const Icon(Icons.delete_outline, color: Colors.red),
                  title: Text(
                    L.t('Delete', ru: 'Удалить'),
                    style: const TextStyle(color: Colors.red),
                  ),
                  onTap: () => Navigator.pop(context, 'delete'),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'react':
        await _reactToMessage(message);
        break;
      case 'reply':
        setState(() => _replyTo = message);
        break;
      case 'pin':
        await CommsScope.read(context)
            .setMessagePinned(conversation.id, message, true);
        break;
      case 'unpin':
        await CommsScope.read(context)
            .setMessagePinned(conversation.id, message, false);
        break;
      case 'forward':
        await _forwardMessage(message);
        break;
      case 'copy':
        await Clipboard.setData(ClipboardData(text: message.body));
        if (mounted) {
          CommsScope.read(context).showSnack(L.t('Copied', ru: 'Скопировано'));
        }
        break;
      case 'scan-link':
        await _scanWithVirusTotal(message);
        break;
      case 'edit':
        _input.text = message.body;
        setState(() {
          _editing = message;
          _replyTo = null;
        });
        break;
      case 'delete':
        await _confirmDelete(message);
        break;
    }
  }

  Future<void> _reactToMessage(Message message) async {
    final emoji = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                L.t('React', ru: 'Реакция'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final e in _kReactionEmojis)
                    ActionChip(
                      label: Text(e, style: const TextStyle(fontSize: 18)),
                      onPressed: () => Navigator.pop(context, e),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (!mounted || emoji == null) return;
    await CommsScope.read(context)
        .toggleReaction(conversation.id, message, emoji);
  }

  Future<void> _forwardMessage(Message message) async {
    final controller = CommsScope.read(context);
    final pickOption = await showModalBottomSheet<(String, String)>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                L.t('Forward to…', ru: 'Переслать…'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final c in controller.conversations) ...[
              ListTile(
                leading: c.isGroup
                    ? const Icon(Icons.group)
                    : const Icon(Icons.person_outline),
                title: Text(c.title, overflow: TextOverflow.ellipsis),
                onTap: () => Navigator.pop(context, (c.id, c.title)),
              ),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || pickOption == null) return;
    await controller.forwardMessage(message, pickOption.$1);
    controller.showSnack(
      L.t('Forwarded to ${pickOption.$2}', ru: 'Переслано в ${pickOption.$2}'),
    );
  }

  Future<void> _confirmDelete(Message message) async {
    final controller = CommsScope.read(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(L.t('Delete message?', ru: 'Удалить сообщение?')),
        content: Text(
          L.t(
            'The message will be removed for everyone.',
            ru: 'Сообщение будет удалено у всех.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(L.t('Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(L.t('Delete', ru: 'Удалить')),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await controller.deleteMessage(conversation.id, message);
    }
  }

  Future<void> _scanWithVirusTotal(Message message) async {
    final key = await AppConfig.loadVirusTotalKey();
    if (key == null || key.isEmpty) {
      if (!mounted) return;
      CommsScope.read(context).showSnack(
        L.t(
          'Add your VirusTotal API key in Settings - Security',
          ru: 'Добавьте API-ключ VirusTotal в разделе «Настройки — Безопасность»',
        ),
      );
      return;
    }
    final urls = UrlService.findUrls(message.body);
    if (urls.isEmpty) return;
    final url = UrlService.normalize(urls.first);
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const _ScanLinkDialog(),
    );
    Map<String, int> stats;
    try {
      final proxy = await AppConfig.loadVirusTotalProxy();
      stats = await VirusTotalService.scanUrl(key, url, proxy: proxy);
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      CommsScope.read(context).showSnack(
        e is VirusTotalException
            ? e.message
            : L.t(
                'VirusTotal check failed: $e',
                ru: 'Проверка VirusTotal не удалась: $e',
              ),
      );
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    await showScanResult(context: context, subject: url, stats: stats);
  }

  Widget _blockedBanner() {
    return Material(
      color: Theme.of(context).colorScheme.errorContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(
                Icons.block,
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  L.t(
                    'You blocked this contact.',
                    ru: 'Вы заблокировали этот контакт.',
                  ),
                ),
              ),
              TextButton(
                onPressed: () async {
                  final peer = conversation.peer;
                  if (peer == null) return;
                  final c = CommsScope.read(context);
                  await c.unblockUser(peer);
                },
                child: Text(L.t('Unblock', ru: 'Разблокировать')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _messageList(CommsController controller) {
    final messages = controller.messages(conversation.id);
    final me = controller.user?.id;

    final list = NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.pixels >=
            notification.metrics.maxScrollExtent - 40) {
          if (controller.hasMoreMessages(conversation.id)) {
            controller.loadMessages(conversation.id, older: true);
          }
        }
        return false;
      },
      child: messages.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  L.t(
                    'No messages yet. Say hello!',
                    ru: 'Пока нет сообщений. Поприветствуйте собеседника!',
                  ),
                ),
              ),
            )
          : ListView.builder(
              controller: _scroll,
              reverse: true,
              padding: const EdgeInsets.symmetric(vertical: 12),
              itemCount: messages.length,
              itemBuilder: (context, index) {
                final message = messages[messages.length - 1 - index];
                if (message.kind == MessageKind.game) {
                  return _GameBubble(message: message, me: me);
                }
                final mine = message.senderId == me;
                final quoted = _quotedMessage(messages, message);
                if (conversation.isGroup && !mine) {
                  final name =
                      message.senderName ??
                      conversation.memberName(message.senderId);
                  return _MessageBubble(
                    message: message,
                    mine: mine,
                    me: me,
                    senderName: name,
                    quoted: quoted,
                    onLongPress: () => _showMessageActions(message),
                    onLinkTap: (url) => UrlService.open(url),
                    onReactTap: (emoji) => controller.toggleReaction(
                      conversation.id,
                      message,
                      emoji,
                    ),
                  );
                }
                return _MessageBubble(
                  message: message,
                  mine: mine,
                  me: me,
                  quoted: quoted,
                  onLongPress: () => _showMessageActions(message),
                  onLinkTap: (url) => UrlService.open(url),
                  onReactTap: (emoji) => controller.toggleReaction(
                    conversation.id,
                    message,
                    emoji,
                  ),
                );
              },
            ),
    );

    final pinned = controller.pinnedMessages(conversation.id);
    if (pinned.isEmpty) return list;
    return Column(
      children: [
        _pinnedStrip(controller, pinned, messages),
        Expanded(child: list),
      ],
    );
  }

  /// Resolves the message a bubble is replying to (may be unloaded).
  Message? _quotedMessage(List<Message> messages, Message message) {
    final replyTo = message.replyTo;
    if (replyTo == null) return null;
    for (final m in messages) {
      if (m.id == replyTo) return m;
    }
    return null;
  }

  /// Short preview used in reply quotes / pinned chips.
  String _messageSnippet(Message message) {
    if (message.deleted) return L.t('Message deleted', ru: 'Сообщение удалено');
    return switch (message.kind) {
      MessageKind.file => '📎 ${message.body}',
      MessageKind.game => L.t('🎮 Minigame', ru: '🎮 Мини-игра'),
      _ => message.body,
    };
  }

  Widget _pinnedStrip(
    CommsController controller,
    List<Message> pinned,
    List<Message> messages,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: SizedBox(
        height: 42,
        child: Row(
          children: [
            const SizedBox(width: 12),
            Icon(Icons.push_pin, size: 16, color: scheme.primary),
            const SizedBox(width: 6),
            Expanded(
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(vertical: 6),
                itemCount: pinned.length,
                itemBuilder: (context, i) {
                  final pm = pinned[i];
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ActionChip(
                      avatar: Icon(
                        Icons.push_pin_outlined,
                        size: 14,
                        color: scheme.onSurfaceVariant,
                      ),
                      label: Text(
                        _messageSnippet(pm),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _scrollToPinned(messages, pm),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _scrollToPinned(List<Message> messages, Message pinned) {
    if (!_scroll.hasClients) return;
    final pos = messages.indexWhere((m) => m.id == pinned.id);
    if (pos < 0) return;
    // The list is reversed; nudge toward the target's pixel offset (approximate
    // for fixed-height bubbles) and clamp to the scroll extent.
    final index = messages.length - 1 - pos;
    final target = (index * 84.0).clamp(0.0, double.infinity);
    final extent = _scroll.position.maxScrollExtent;
    _scroll.animateTo(
      target > extent ? extent : target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  Widget _inputStatus(CommsController controller) {
    final String? line;
    final sendingName = controller.fileSendingName(conversation.id);
    final sendingUser = controller.fileSendingUser(conversation.id);
    if (sendingName != null) {
      final who = _userName(sendingUser);
      line = who.isEmpty
          ? L.t('is sending: $sendingName…', ru: 'отправляет: $sendingName…')
          : L.t(
              '$who is sending: $sendingName…',
              ru: '$who отправляет: $sendingName…',
            );
    } else {
      final typing = controller.typingUser(conversation.id);
      if (typing == null) return const SizedBox.shrink();
      final who = _userName(typing);
      line = who.isEmpty
          ? L.t('is typing…', ru: 'печатает…')
          : L.t('$who is typing…', ru: '$who печатает…');
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(line, style: Theme.of(context).textTheme.bodySmall),
      ),
    );
  }

  /// User-visible name for a participant id (display name in DMs, member name
  /// in groups).
  String _userName(String? userId) {
    if (userId == null) return '';
    if (!conversation.isGroup) {
      return conversation.peer?.displayName ?? '';
    }
    return conversation.memberName(userId) ?? '';
  }

  Widget _pendingFileChip() {
    final file = _pendingFile;
    if (file == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      padding: const EdgeInsets.fromLTRB(10, 2, 4, 2),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            Icons.insert_drive_file,
            size: 18,
            color: scheme.onSecondaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              file.name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            FileService.formatSize(_pendingFileSize ?? 0),
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            visualDensity: VisualDensity.compact,
            tooltip: L.t('Remove attachment', ru: 'Удалить вложение'),
            onPressed: () => setState(() {
              _pendingFile = null;
              _pendingFileSize = null;
            }),
          ),
        ],
      ),
    );
  }

  Future<void> _openGamesMenu() async {
    final controller = CommsScope.read(context);
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                L.t('Minigames', ru: 'Мини-игры'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ListTile(
              leading: const Text('🪨📄✂️', style: TextStyle(fontSize: 22)),
              title: Text(
                L.t('Rock Paper Scissors', ru: 'Камень, ножницы, бумага'),
              ),
              subtitle: Text(
                L.t(
                  'Best of one — pick your move',
                  ru: 'Один раунд — сделайте ход',
                ),
              ),
              onTap: () => Navigator.pop(context, 'rps'),
            ),
            ListTile(
              leading: const Text('🪙', style: TextStyle(fontSize: 22)),
              title: Text(L.t('Coin Flip', ru: 'Орёл или решка')),
              subtitle: Text(
                L.t('Call heads or tails', ru: 'Загадайте орла или решку'),
              ),
              onTap: () => Navigator.pop(context, 'flip'),
            ),
            ListTile(
              leading: const Text('🎯', style: TextStyle(fontSize: 22)),
              title: Text(L.t('Guess the Number', ru: 'Угадай число')),
              subtitle: Text(
                L.t(
                  'Pick a secret 1–100, they guess it',
                  ru: 'Загадайте число от 1 до 100, собеседник попробует угадать',
                ),
              ),
              onTap: () => Navigator.pop(context, 'guess'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'rps':
        await controller.startGame(conversation.id, type: 'rps');
        break;
      case 'flip':
        await _flipCoinDialog();
        break;
      case 'guess':
        await _guessSecretDialog();
        break;
    }
  }

  Future<void> _flipCoinDialog() async {
    final controller = CommsScope.read(context);
    final call = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(
          L.t('Coin flip — call it!', ru: 'Монетка — делайте ставку!'),
        ),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'heads'),
            child: Text(L.t('🪙 Heads', ru: '🪙 Орёл')),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'tails'),
            child: Text(L.t('🪙 Tails', ru: '🪙 Решка')),
          ),
        ],
      ),
    );
    if (call == null || !mounted) return;
    await controller.flipCoin(conversation.id, call);
  }

  Future<void> _guessSecretDialog() async {
    final controller = CommsScope.read(context);
    final textController = TextEditingController();
    final secret = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          L.t('Choose your secret number', ru: 'Выберите секретное число'),
        ),
        content: TextField(
          controller: textController,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            hintText: '1–100',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(L.t('Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            onPressed: () {
              final n = int.tryParse(textController.text.trim());
              if (n == null || n < 1 || n > 100) {
                controller.showSnack(
                  L.t(
                    'Pick a number between 1 and 100',
                    ru: 'Выберите число от 1 до 100',
                  ),
                );
                return;
              }
              Navigator.pop(context, n);
            },
            child: Text(L.t('Start', ru: 'Начать')),
          ),
        ],
      ),
    );
    textController.dispose();
    if (secret == null) return;
    await controller.startGame(conversation.id, type: 'guess', secret: secret);
  }

  Widget _gamePanel(CommsController controller) {
    final game = controller.activeGame(conversation.id);
    if (game == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 10),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Text('🎮', style: TextStyle(fontSize: 16)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  game.type == 'rps'
                      ? L.t(
                          'Rock Paper Scissors',
                          ru: 'Камень, ножницы, бумага',
                        )
                      : L.t('Guess the Number', ru: 'Угадай число'),
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                visualDensity: VisualDensity.compact,
                tooltip: L.t('Close panel', ru: 'Закрыть панель'),
                onPressed: () => controller.dismissGamePanel(conversation.id),
              ),
            ],
          ),
          if (game.type == 'rps')
            _rpsPanel(controller, game, scheme)
          else
            _guessPanel(controller, game, scheme),
        ],
      ),
    );
  }

  Widget _rpsPanel(
    CommsController controller,
    ActiveGame game,
    ColorScheme scheme,
  ) {
    final moves = [
      ('rock', '✊', L.t('Rock', ru: 'Камень')),
      ('paper', '🖐️', L.t('Paper', ru: 'Бумага')),
      ('scissors', '✌️', L.t('Scissors', ru: 'Ножницы')),
    ];
    final String status;
    if (game.myMoved && !game.peerMoved) {
      status = L.t(
        'You picked — waiting for $_peerName…',
        ru: 'Вы выбрали — ждём $_peerName…',
      );
    } else if (!game.myMoved && game.peerMoved) {
      status = L.t(
        '$_peerName picked! Your turn.',
        ru: '$_peerName сделал выбор! Ваш ход.',
      );
    } else if (game.myMoved && game.peerMoved) {
      status = L.t('Both picked — showdown!', ru: 'Оба выбрали — сверка!');
    } else {
      status = game.mine
          ? L.t(
              'You challenged $_peerName! Pick your move.',
              ru: 'Вы бросили вызов $_peerName! Сделайте ход.',
            )
          : L.t(
              '$_peerName challenged you! Pick your move.',
              ru: '$_peerName бросил вам вызов! Сделайте ход.',
            );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 6, top: 4, bottom: 6),
          child: Text(
            status,
            style: TextStyle(fontSize: 12, color: scheme.onSecondaryContainer),
          ),
        ),
        Row(
          children: [
            for (final (move, emoji, label) in moves) ...[
              Expanded(
                child: FilledButton.tonal(
                  onPressed: game.myMoved
                      ? null
                      : () =>
                            controller.playMove(conversation.id, game.id, move),
                  child: Text(
                    '$emoji $label',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
              if (move != 'scissors') const SizedBox(width: 8),
            ],
          ],
        ),
      ],
    );
  }

  Widget _guessPanel(
    CommsController controller,
    ActiveGame game,
    ColorScheme scheme,
  ) {
    if (game.mine) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 6, top: 4, bottom: 2),
            child: Text(
              L.t(
                'Secret: ${game.mySecret} · guesses so far: ${game.guesses}. '
                '$_peerName is on it.',
                ru:
                    'Секрет: ${game.mySecret} · попыток: ${game.guesses}. '
                    '$_peerName в деле.',
              ),
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSecondaryContainer,
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () =>
                  controller.playMove(conversation.id, game.id, 'forfeit'),
              icon: const Icon(Icons.flag, size: 16),
              label: Text(L.t('Give up', ru: 'Сдаться')),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 6, top: 4, bottom: 6),
          child: Text(
            L.t(
              '$_peerName picked a number (1–100). '
              'Guesses so far: ${game.guesses}.',
              ru:
                  '$_peerName загадал число (1–100). '
                  'Попыток: ${game.guesses}.',
            ),
            style: TextStyle(fontSize: 12, color: scheme.onSecondaryContainer),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _guessInput,
                keyboardType: TextInputType.number,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: L.t('Your guess…', ru: 'Ваша попытка…'),
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                ),
                onSubmitted: (_) => _sendGuess(controller, game),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.send),
              tooltip: L.t('Guess', ru: 'Угадать'),
              visualDensity: VisualDensity.compact,
              onPressed: () => _sendGuess(controller, game),
            ),
          ],
        ),
      ],
    );
  }

  void _sendGuess(CommsController controller, ActiveGame game) {
    final text = _guessInput.text.trim();
    _guessInput.clear();
    if (text.isEmpty) return;
    controller.playMove(conversation.id, game.id, text);
  }

  Widget _inputBar(CommsController controller) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_replyTo != null || _editing != null) _composerChip(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.attach_file),
                    tooltip: L.t('Send file', ru: 'Отправить файл'),
                    onPressed: _sending ? null : _attach,
                  ),
                  if (!conversation.isGroup)
                    IconButton(
                      icon: const Icon(Icons.sports_esports),
                      tooltip: L.t('Games', ru: 'Игры'),
                      onPressed: _sending ? null : _openGamesMenu,
                    ),
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.send,
                      onChanged: (_) => _onTyping(),
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: _editing != null
                            ? L.t('Edit message', ru: 'Изменить сообщение')
                            : L.t('Message', ru: 'Сообщение'),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        filled: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton.filled(
                    icon: const Icon(Icons.send),
                    tooltip: L.t('Send', ru: 'Отправить'),
                    onPressed: _sending ? null : _send,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Composer overlay shown while replying to or editing a message.
  Widget _composerChip() {
    final scheme = Theme.of(context).colorScheme;
    final editing = _editing != null;
    final String label;
    final IconData icon;
    if (editing) {
      label = L.t('Editing message', ru: 'Редактирование сообщения');
      icon = Icons.edit_outlined;
    } else {
      final reply = _replyTo!;
      final me = CommsScope.read(context).user?.id;
      final who = reply.senderId == me
          ? L.t('You', ru: 'Вы')
          : (reply.senderName ?? _userName(reply.senderId));
      label = L.t(
        'Replying to $who: ${_messageSnippet(reply)}',
        ru: 'Ответ для $who: ${_messageSnippet(reply)}',
      );
      icon = Icons.reply;
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: scheme.onSecondaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            visualDensity: VisualDensity.compact,
            tooltip: L.t('Cancel', ru: 'Отмена'),
            onPressed: () => setState(() {
              _replyTo = null;
              _editing = null;
              _input.clear();
            }),
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final Message message;
  final bool mine;
  final String? me;
  final String? senderName;
  final Message? quoted;
  final VoidCallback? onLongPress;
  final void Function(String url)? onLinkTap;
  final void Function(String emoji)? onReactTap;

  const _MessageBubble({
    required this.message,
    required this.mine,
    this.me,
    this.senderName,
    this.quoted,
    this.onLongPress,
    this.onLinkTap,
    this.onReactTap,
  });

  static const _palette = [
    Colors.indigo,
    Colors.teal,
    Colors.deepPurple,
    Colors.brown,
    Colors.pink,
    Colors.blueGrey,
  ];

  Color _senderColor(String name) {
    return _palette[name.hashCode.abs() % _palette.length];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bubbleColor = mine
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest;
    final textColor = mine ? scheme.onPrimaryContainer : scheme.onSurface;
    final showSender = !mine && senderName != null && senderName!.isNotEmpty;
    final quote = quoted;
    final myId = me;

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onLongPress,
        // Desktop right-click ("secondary tap") opens the same actions menu.
        onSecondaryTap: onLongPress,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78,
          ),
          decoration: BoxDecoration(
            color: bubbleColor,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(mine ? 16 : 4),
              bottomRight: Radius.circular(mine ? 4 : 16),
            ),
          ),
          child: Column(
            crossAxisAlignment: showSender
                ? CrossAxisAlignment.start
                : CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showSender)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    senderName!,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: _senderColor(senderName!),
                    ),
                  ),
                ),
              if (message.forwarded)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    L.t('Forwarded', ru: 'Переслано'),
                    style: TextStyle(
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                      color: textColor.withValues(alpha: 0.6),
                    ),
                  ),
                ),
              if (message.pinned)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.push_pin, size: 12, color: scheme.primary),
                      const SizedBox(width: 3),
                      Text(
                        L.t('Pinned', ru: 'Закреплено'),
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              if (quote != null && !message.deleted)
                Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: bubbleColor.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(8),
                    border: Border(
                      left: BorderSide(color: scheme.primary, width: 3),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        quote.senderId == me
                            ? L.t('You', ru: 'Вы')
                            : (quote.senderName ?? _groupName(context, quote)),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: scheme.primary,
                        ),
                      ),
                      Text(
                        _snippet(quote),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: textColor.withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                  ),
                ),
              if (message.deleted)
                Text(
                  L.t('Message deleted', ru: 'Сообщение удалено'),
                  style: TextStyle(
                    fontStyle: FontStyle.italic,
                    color: textColor.withValues(alpha: 0.6),
                  ),
                )
              else if (message.kind == MessageKind.text)
                _LinkifiedText(
                  text: message.body,
                  style: TextStyle(color: textColor),
                  onUrlTap: onLinkTap,
                )
              else
                _FileAttachmentTile(message: message),
              if (message.reactions.isNotEmpty && !message.deleted)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (final reaction in message.reactions)
                        _ReactionChip(
                          emoji: reaction.emoji,
                          count: reaction.userIds.length,
                          active: myId != null && reaction.reactedBy(myId),
                          onTap: onReactTap == null
                              ? null
                              : () => onReactTap!(reaction.emoji),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 3),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    formatClock(message.createdAt),
                    style: TextStyle(
                      color: textColor.withValues(alpha: 0.6),
                      fontSize: 10,
                    ),
                  ),
                  if (message.edited) ...[
                    const SizedBox(width: 3),
                    Text(
                      L.t('edited', ru: 'изменено'),
                      style: TextStyle(
                        color: textColor.withValues(alpha: 0.6),
                        fontSize: 10,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                  if (mine) ...[
                    const SizedBox(width: 3),
                    Icon(
                      message.readAt != null ? Icons.done_all : Icons.done,
                      size: 14,
                      color: message.readAt != null
                          ? scheme.primary
                          : textColor.withValues(alpha: 0.6),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _snippet(Message m) {
    if (m.deleted) return L.t('Message deleted', ru: 'Сообщение удалено');
    return switch (m.kind) {
      MessageKind.file => '📎 ${m.body}',
      MessageKind.game => L.t('🎮 Minigame', ru: '🎮 Мини-игра'),
      _ => m.body,
    };
  }

  String _groupName(BuildContext context, Message m) {
    final conv = CommsScope.read(context).conversationById(m.conversationId);
    if (conv == null || !conv.isGroup) return m.senderName ?? '';
    return conv.memberName(m.senderId) ?? m.senderName ?? '';
  }
}

class _LinkifiedText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final void Function(String url)? onUrlTap;

  const _LinkifiedText({
    required this.text,
    required this.style,
    this.onUrlTap,
  });

  @override
  State<_LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends State<_LinkifiedText> {
  List<TapGestureRecognizer>? _recognizers;

  @override
  void dispose() {
    _clearRecognizers();
    super.dispose();
  }

  void _clearRecognizers() {
    for (final r in _recognizers ?? const <TapGestureRecognizer>[]) {
      r.dispose();
    }
    _recognizers = null;
  }

  @override
  Widget build(BuildContext context) {
    _clearRecognizers();
    final linkColor = Theme.of(context).colorScheme.primary;
    final spans = <InlineSpan>[];
    final recognizers = <TapGestureRecognizer>[];
    var index = 0;
    for (final match in UrlService.urlPattern.allMatches(widget.text)) {
      if (match.start > index) {
        spans.add(TextSpan(text: widget.text.substring(index, match.start)));
      }
      final url = match.group(0)!;
      final recognizer = TapGestureRecognizer()
        ..onTap = () => widget.onUrlTap?.call(url);
      recognizers.add(recognizer);
      spans.add(
        TextSpan(
          text: url,
          style: widget.style.copyWith(
            color: linkColor,
            decoration: TextDecoration.underline,
          ),
          recognizer: recognizer,
        ),
      );
      index = match.end;
    }
    if (index < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(index)));
    }
    _recognizers = recognizers;
    return RichText(
      text: TextSpan(style: widget.style, children: spans),
    );
  }
}

class _ScanLinkDialog extends StatelessWidget {
  const _ScanLinkDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: Row(
        children: [
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Text(
              L.t(
                'Checking link with VirusTotal\u2026',
                ru: 'Проверяем ссылку через VirusTotal\u2026',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReactionChip extends StatelessWidget {
  final String emoji;
  final int count;
  final bool active;
  final VoidCallback? onTap;

  const _ReactionChip({
    required this.emoji,
    required this.count,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: active
          ? scheme.secondaryContainer
          : scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(emoji, style: const TextStyle(fontSize: 12)),
              const SizedBox(width: 3),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: active ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GameBubble extends StatelessWidget {
  final Message message;
  final String? me;

  const _GameBubble({required this.message, required this.me});

  static const _rpsEmoji = {'rock': '✊', 'paper': '🖐️', 'scissors': '✌️'};

  String? _label(Map<String, dynamic> data) {
    switch (data['type']) {
      case 'rps':
        if (data['phase'] == 'invite') {
          return L.t(
            '🪨📄✂️ Rock Paper Scissors!',
            ru: '🪨📄✂️ Камень, ножницы, бумага!',
          );
        }
        if (data['phase'] == 'result') {
          final aMove = _rpsEmoji[data['aMove']] ?? data['aMove'];
          final bMove = _rpsEmoji[data['bMove']] ?? data['bMove'];
          final winner = data['winner'];
          final String verdict;
          if (winner == 'draw') {
            verdict = L.t('It\'s a draw!', ru: 'Ничья!');
          } else {
            verdict = me != null && winner == me
                ? L.t('You won! 🎉', ru: 'Вы выиграли! 🎉')
                : L.t('You lost 😅', ru: 'Вы проиграли 😅');
          }
          return L.t(
            '$aMove vs $bMove — $verdict',
            ru: '$aMove против $bMove — $verdict',
          );
        }
        return null;
      case 'guess':
        if (data['phase'] == 'invite') {
          return L.t(
            '🎯 Guess the number (1–100)!',
            ru: '🎯 Угадай число (1–100)!',
          );
        }
        if (data['phase'] == 'hint') {
          final hint = data['hint'] == 'higher'
              ? L.t(
                  'too low — guess higher!',
                  ru: 'слишком мало — попробуйте больше!',
                )
              : L.t(
                  'too high — guess lower!',
                  ru: 'слишком много — попробуйте меньше!',
                );
          return L.t(
            '🔺 ${data['guess']} is $hint',
            ru: '🔺 ${data['guess']} — $hint',
          );
        }
        if (data['phase'] == 'result') {
          if (data['forfeited'] == true) {
            return L.t(
              '🏳️ The game was abandoned.',
              ru: '🏳️ Игра заброшена.',
            );
          }
          final guesses = data['guesses'] ?? 0;
          final secret = data['secret'];
          if (me != null && data['winner'] == me) {
            return L.plural(
              guesses,
              enOne: '🎉 You guessed it in 1 try!',
              enMany: '🎉 You guessed it in $guesses tries!',
              ruOne: '🎉 Вы угадали с первой попытки!',
              ruFew: '🎉 Вы угадали за $guesses попытки!',
              ruMany: '🎉 Вы угадали за $guesses попыток!',
            );
          }
          return L.plural(
            guesses,
            enOne: '🔎 The secret was $secret (solved in 1 try).',
            enMany: '🔎 The secret was $secret (solved in $guesses tries).',
            ruOne: '🔎 Секрет был $secret (решено с первой попытки).',
            ruFew: '🔎 Секрет был $secret (решено за $guesses попытки).',
            ruMany: '🔎 Секрет был $secret (решено за $guesses попыток).',
          );
        }
        return null;
      case 'flip':
        final call = data['call'];
        final flip = data['flip'];
        final win = data['win'] == true;
        final callerIsMe = message.senderId == me;
        final line = callerIsMe
            ? L.t(
                'You called $call — $flip came up!',
                ru: 'Вы поставили на $call — выпало $flip!',
              )
            : L.t(
                '$call called, and $flip came up!',
                ru: '$call поставили, выпало $flip!',
              );
        return win
            ? L.t(
                '🪙 $line ${callerIsMe ? 'You won!' : 'They won!'} 🎉',
                ru: '🪙 $line ${callerIsMe ? 'Вы выиграли!' : 'Они выиграли!'} 🎉',
              )
            : L.t(
                '🪙 $line ${callerIsMe ? 'So close!' : 'Better luck next time!'}',
                ru: '🪙 $line ${callerIsMe ? 'Так близко!' : 'Удачи в следующий раз!'}',
              );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final data = message.gameData;
    final label = data == null ? null : _label(data);
    if (label == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 32, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 2),
            Text(
              formatClock(message.createdAt),
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}

class _FileAttachmentTile extends StatelessWidget {
  final Message message;

  const _FileAttachmentTile({required this.message});

  @override
  Widget build(BuildContext context) {
    final attachment = message.attachment;
    if (attachment == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () async {
        final token = CommsScope.read(context).token;
        if (token == null) return;
        final error = await AttachmentHelper.downloadAndOpen(token, attachment);
        if (error != null && context.mounted) {
          CommsScope.read(context).showSnack(error);
        }
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.insert_drive_file,
              color: scheme.onSecondaryContainer,
            ),
          ),
          const SizedBox(width: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  attachment.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  L.t(
                    '${FileService.formatSize(attachment.size)} · tap to open',
                    ru: '${FileService.formatSize(attachment.size)} · нажмите, чтобы открыть',
                  ),
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
