import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/api.dart';
import '../../models.dart';
import '../../services/comms_controller.dart';
import '../../widgets/user_avatar.dart';
import '../account/account_switcher.dart';
import '../call/call_screen.dart';
import '../chat/chat_screen.dart';
import '../profile/profile_screen.dart';
import '../../core/localizations.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  final _search = TextEditingController();
  List<User> _users = const [];
  bool _loading = true;
  CommsController? _controller;
  String? _accountId;

  @override
  void initState() {
    super.initState();
    _controller = CommsScope.read(context);
    _accountId = _controller!.activeAccountId;
    _controller!.addListener(_onAccountChanged);
    _search.addListener(() => setState(() {}));
    _load();
  }

  /// The People tab stays mounted while another tab is visible, so switching
  /// accounts must clear the old directory and fetch the new one.
  void _onAccountChanged() {
    final id = _controller?.activeAccountId;
    if (id == _accountId) return;
    _accountId = id;
    if (!mounted) return;
    setState(() {
      _users = const [];
      _loading = true;
    });
    _load();
  }

  @override
  void dispose() {
    _controller?.removeListener(_onAccountChanged);
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final controller = CommsScope.read(context);
    final token = controller.token;
    if (token == null) return;
    setState(() => _loading = true);
    try {
      final users = await Api.users(token, query: _search.text.trim());
      if (!mounted) return;
      setState(() {
        _users = users;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _chat(User user) async {
    final controller = CommsScope.read(context);
    final conv = await controller.openConversation(user);
    if (!mounted || conv == null) return;
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => ChatScreen(conversation: conv)));
  }

  Future<void> _call(User user, bool video) async {
    final controller = CommsScope.read(context);
    final ok = await controller.startCall(user, video: video);
    if (ok && mounted) {
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const CallScreen()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = CommsScope.of(context);
    final query = _search.text.trim().toLowerCase();
    final visible = _users
        .where(
          (u) =>
              u.displayName.toLowerCase().contains(query) ||
              u.username.toLowerCase().contains(query),
        )
        .toList();

    return Scaffold(
      appBar: AppBar(
        leading: const AccountButton(),
        title: Text(L.t('People', ru: 'Контакты')),
        actions: [
          IconButton(
            tooltip: L.t('Refresh', ru: 'Обновить'),
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _search,
              decoration: InputDecoration(
                hintText: L.t('Search…', ru: 'Поиск…'),
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
                : visible.isEmpty
                ? Center(
                    child: Text(
                      L.t('No users found', ru: 'Пользователи не найдены'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  )
                : ListView.builder(
                    itemCount: visible.length,
                    itemBuilder: (context, index) {
                      final user = visible[index];
                      final online = controller.isOnline(user.id);
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
                            showOnline: online,
                            isVerified: user.isVerified,
                            radius: 24,
                          ),
                        ),
                        title: Text(
                          user.displayName,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Row(
                          children: [
                            Flexible(child: Text('@${user.username}')),
                            if (user.isBot) ...[
                              const SizedBox(width: 6),
                              Icon(
                                Icons.smart_toy_outlined,
                                size: 14,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                              const SizedBox(width: 2),
                              Text(
                                L.t('Bot', ru: 'Бот'),
                                style: Theme.of(context)
                                    .textTheme
                                    .labelSmall
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                            ],
                          ],
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: L.t('Message', ru: 'Сообщение'),
                              icon: const Icon(Icons.chat_bubble_outline),
                              onPressed: () => _chat(user),
                            ),
                            if (!user.isBot) ...[
                              IconButton(
                                tooltip: L.t(
                                  'Voice call',
                                  ru: 'Голосовой звонок',
                                ),
                                icon: const Icon(Icons.call),
                                onPressed: () => _call(user, false),
                              ),
                              IconButton(
                                tooltip: L.t('Video call', ru: 'Видеозвонок'),
                                icon: const Icon(Icons.videocam_outlined),
                                onPressed: () => _call(user, true),
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
