import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app.dart';
import '../../core/api.dart';
import '../../models.dart';
import '../../services/attachment_helper.dart';
import '../../widgets/user_avatar.dart';
import '../profile/profile_screen.dart';
import 'chat_screen.dart';
import 'create_group_screen.dart';
import 'group_info_sheet.dart';
import '../../core/localizations.dart';

class ConversationsScreen extends StatefulWidget {
  const ConversationsScreen({super.key});

  @override
  State<ConversationsScreen> createState() => _ConversationsScreenState();
}

class _ConversationsScreenState extends State<ConversationsScreen> {
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      CommsScope.read(context).refreshConversations();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = CommsScope.of(context);
    final conversations = controller.sortedConversations;

    return Scaffold(
      appBar: AppBar(
        title: Text(L.t('Chats', ru: 'Чаты')),
        actions: [
          IconButton(
            tooltip: L.t('New group', ru: 'Новая группа'),
            icon: const Icon(Icons.group_add_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const CreateGroupScreen()),
            ),
          ),
          ValueListenableBuilder(
            valueListenable: controller.channel.connected,
            builder: (context, connected, _) => Padding(
              padding: const EdgeInsets.only(right: 16, top: 18, bottom: 18),
              child: Tooltip(
                message: connected
                    ? L.t('Online', ru: 'В сети')
                    : L.t('Disconnected', ru: 'Нет соединения'),
                child: Icon(
                  connected ? Icons.cloud_done : Icons.cloud_off,
                  size: 20,
                  color: connected ? Colors.green : Colors.grey,
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () =>
            Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const NewChatScreen())),
        child: const Icon(Icons.edit),
      ),
      body: conversations.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.forum_outlined,
                    size: 64,
                    color: Colors.grey,
                  ),
                  const SizedBox(height: 12),
                  Text(L.t('No conversations yet', ru: 'Пока нет бесед')),
                  const SizedBox(height: 4),
                  Text(
                    L.t(
                      'Start one from the People tab or tap +',
                      ru: 'Начните из вкладки «Люди» или нажмите +',
                    ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            )
          : ListView.builder(
              itemCount: conversations.length,
              itemBuilder: (context, index) {
                final conv = conversations[index];
                return _ConversationTile(conversation: conv);
              },
            ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  final Conversation conversation;

  const _ConversationTile({required this.conversation});

  @override
  Widget build(BuildContext context) {
    final controller = CommsScope.of(context);
    final typing = controller.typingUser(conversation.id);
    final isGroup = conversation.isGroup;
    final peer = isGroup ? null : conversation.peer;
    final last = conversation.lastMessage;
    final online = peer != null && controller.isOnline(peer.id);

    String? subtitle;
    if (typing != null) {
      subtitle = isGroup
          ? L.t(
              '${conversation.memberName(typing) ?? 'Someone'} is typing…',
              ru: '${conversation.memberName(typing) ?? 'Кто-то'} печатает…',
            )
          : L.t('typing…', ru: 'печатает…');
    } else if (last != null) {
      final preview = previewOf(last);
      if (isGroup) {
        final name = last.senderId == controller.user?.id
            ? ''
            : (last.senderName ?? conversation.memberName(last.senderId) ?? '');
        subtitle = name.isEmpty ? preview : '$name: $preview';
      } else {
        subtitle = preview;
      }
    }
    subtitle ??= isGroup
        ? L.t('Group chat', ru: 'Групповой чат')
        : L.t('Say hello 👋', ru: 'Поздоровайтесь 👋');

    return ListTile(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(conversation: conversation),
        ),
      ),
      leading: InkWell(
        customBorder: const CircleBorder(),
        onTap: () {
          if (isGroup) {
            showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              builder: (context) => GroupInfoSheet(conversation: conversation),
            );
          } else {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) =>
                    ProfileScreen(peer: peer!, conversation: conversation),
              ),
            );
          }
        },
        child: UserAvatar(
          name: isGroup ? conversation.title : peer!.displayName,
          seed: isGroup ? conversation.id : peer!.username,
          showOnline: isGroup ? false : online,
          radius: 24,
        ),
      ),
      title: Text(
        isGroup ? conversation.title : peer!.displayName,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: typing != null ? const TextStyle(color: Colors.blue) : null,
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            last != null
                ? _time(last.createdAt)
                : _time(conversation.createdAt),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (isGroup && conversation.muted) ...[
            const SizedBox(height: 3),
            Icon(
              Icons.notifications_off_outlined,
              size: 14,
              color: Colors.grey.shade600,
            ),
          ],
          if (conversation.unread > 0) ...[
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${conversation.unread}',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _time(DateTime time) {
    final l = time.toLocal();
    final now = DateTime.now();
    final diff = now.difference(l);
    if (diff.inDays == 0) return DateFormat('HH:mm').format(l);
    if (diff.inDays == 1) return L.t('Yesterday', ru: 'Вчера');
    return DateFormat('dd MMM').format(l);
  }
}

class NewChatScreen extends StatefulWidget {
  const NewChatScreen({super.key});

  @override
  State<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends State<NewChatScreen> {
  final _search = TextEditingController();
  List<User> _results = const [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _search.addListener(_onQuery);
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _onQuery() {
    if (_search.text.trim().isEmpty) {
      setState(() => _results = const []);
      return;
    }
    _load(query: _search.text.trim());
  }

  Future<void> _load({String query = ''}) async {
    final controller = CommsScope.read(context);
    final token = controller.token;
    if (token == null) return;
    setState(() => _loading = true);
    try {
      final users = await Api.users(token, query: query);
      if (!mounted) return;
      setState(() {
        _results = users;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _startChat(User user) async {
    final controller = CommsScope.read(context);
    final conv = await controller.openConversation(user);
    if (!mounted || conv == null) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => ChatScreen(conversation: conv)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(L.t('New chat', ru: 'Новый чат'))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _search,
              decoration: InputDecoration(
                hintText: L.t('Search users…', ru: 'Поиск пользователей…'),
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(28),
                ),
                suffixIcon: _search.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => _search.clear(),
                      )
                    : null,
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _results.isEmpty
                ? Center(
                    child: Text(
                      _search.text.trim().isEmpty
                          ? L.t(
                              'Type a name or username to find people',
                              ru: 'Введите имя или имя пользователя, чтобы найти людей',
                            )
                          : L.t(
                              'No users found',
                              ru: 'Пользователи не найдены',
                            ),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  )
                : ListView.builder(
                    itemCount: _results.length,
                    itemBuilder: (context, index) {
                      final user = _results[index];
                      return ListTile(
                        leading: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ProfileScreen(peer: user),
                            ),
                          ),
                          child: UserAvatar(
                            name: user.displayName,
                            seed: user.username,
                            showOnline: true,
                          ),
                        ),
                        title: Text(user.displayName),
                        subtitle: Text('@${user.username}'),
                        onTap: () => _startChat(user),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
