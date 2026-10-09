import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app.dart';
import '../../core/api.dart';
import '../../models.dart';
import '../../core/localizations.dart';

class ModBannedScreen extends StatefulWidget {
  const ModBannedScreen({super.key});

  @override
  State<ModBannedScreen> createState() => _ModBannedScreenState();
}

class _ModBannedScreenState extends State<ModBannedScreen> {
  List<User> _users = [];
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final token = CommsScope.read(context).token;
    if (token == null) return;
    setState(() => _loading = true);
    try {
      final users = await Api.bannedUsers(token);
      if (!mounted) return;
      setState(() {
        _users = users;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.t(
              'Failed to load banned accounts: ${e.message}',
              ru: 'Не удалось загрузить заблокированные аккаунты: ${e.message}',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _unban(User user) async {
    final token = CommsScope.read(context).token;
    if (token == null || _busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.lock_open, color: Colors.green),
        title: Text(
          L.t(
            'Unban @${user.username}?',
            ru: 'Разблокировать @${user.username}?',
          ),
        ),
        content: Text(
          L.t(
            '${user.displayName} will be able to log in again.',
            ru: '${user.displayName} снова сможет войти.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(L.t('Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(L.t('Unban', ru: 'Разблокировать')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await Api.setBan(token, user.id, banned: false);
      if (!mounted) return;
      setState(() => _users.removeWhere((u) => u.id == user.id));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.t(
              '@${user.username} unbanned.',
              ru: '@${user.username} разблокирован.',
            ),
          ),
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.t('Failed: ${e.message}', ru: 'Ошибка: ${e.message}'),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _when(DateTime time) {
    final l = time.toLocal();
    final now = DateTime.now();
    final diff = now.difference(l);
    if (diff.inMinutes < 1) return L.t('just now', ru: 'только что');
    if (diff.inMinutes < 60) {
      return L.plural(
        diff.inMinutes,
        enOne: '${diff.inMinutes}m ago',
        enMany: '${diff.inMinutes}m ago',
        ruOne: '${diff.inMinutes} мин назад',
        ruFew: '${diff.inMinutes} мин назад',
        ruMany: '${diff.inMinutes} мин назад',
      );
    }
    if (diff.inHours < 24) {
      return L.plural(
        diff.inHours,
        enOne: '${diff.inHours}h ago',
        enMany: '${diff.inHours}h ago',
        ruOne: '${diff.inHours} ч назад',
        ruFew: '${diff.inHours} ч назад',
        ruMany: '${diff.inHours} ч назад',
      );
    }
    if (diff.inDays < 7) {
      return L.plural(
        diff.inDays,
        enOne: '${diff.inDays}d ago',
        enMany: '${diff.inDays}d ago',
        ruOne: '${diff.inDays} дн назад',
        ruFew: '${diff.inDays} дн назад',
        ruMany: '${diff.inDays} дн назад',
      );
    }
    return DateFormat('dd MMM yyyy').format(l);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(L.t('Banned accounts', ru: 'Заблокированные аккаунты')),
        actions: [
          IconButton(
            tooltip: L.t('Refresh', ru: 'Обновить'),
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _users.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.person_off_outlined,
                    size: 56,
                    color: theme.colorScheme.outline,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    L.t(
                      'No banned accounts',
                      ru: 'Нет заблокированных аккаунтов',
                    ),
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    L.t('Everybody is behaving.', ru: 'Все себя хорошо ведут.'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                itemCount: _users.length,
                itemBuilder: (context, i) {
                  final user = _users[i];
                  return Card(
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    child: ListTile(
                      leading: CircleAvatar(
                        child: Text(
                          user.displayName.isNotEmpty
                              ? user.displayName[0].toUpperCase()
                              : '?',
                        ),
                      ),
                      title: Text(
                        user.displayName.isEmpty
                            ? user.username
                            : user.displayName,
                      ),
                      subtitle: Text(
                        L.t(
                          '@${user.username} · banned ${_when(user.createdAt ?? DateTime.now())}'
                          '${user.bio.isNotEmpty ? ' · ${user.bio}' : ''}',
                          ru:
                              '@${user.username} · заблокирован ${_when(user.createdAt ?? DateTime.now())}'
                              '${user.bio.isNotEmpty ? ' · ${user.bio}' : ''}',
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: FilledButton.tonalIcon(
                        onPressed: _busy ? null : () => _unban(user),
                        icon: const Icon(Icons.lock_open, size: 18),
                        label: Text(L.t('Unban', ru: 'Разблокировать')),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}
