import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/api.dart';
import '../../core/localizations.dart';
import '../../models.dart';
import '../../widgets/user_avatar.dart';

/// Moderator screen for granting and revoking verified badges.
class ModVerifiedScreen extends StatefulWidget {
  const ModVerifiedScreen({super.key});

  @override
  State<ModVerifiedScreen> createState() => _ModVerifiedScreenState();
}

class _ModVerifiedScreenState extends State<ModVerifiedScreen> {
  final _search = TextEditingController();
  List<User> _users = [];
  bool _loading = true;
  String? _busyId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final token = CommsScope.read(context).token;
    if (token == null) return;
    setState(() => _loading = true);
    try {
      final users = await Api.users(token, query: _search.text.trim());
      if (!mounted) return;
      setState(() {
        _users = users;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      CommsScope.read(context).showSnack(e.message);
    }
  }

  Future<void> _toggle(User user) async {
    final token = CommsScope.read(context).token;
    if (token == null || _busyId != null) return;
    setState(() => _busyId = user.id);
    try {
      await Api.setVerified(token, user.id, verified: !user.isVerified);
      if (!mounted) return;
      setState(() {
        final i = _users.indexWhere((u) => u.id == user.id);
        if (i >= 0) {
          _users[i] = _users[i].copyWith(isVerified: !user.isVerified);
        }
        _busyId = null;
      });
      CommsScope.read(context).showSnack(
        !user.isVerified
            ? L.t(
                '@${user.username} is now verified',
                ru: '@${user.username} теперь подтверждён',
              )
            : L.t(
                'Verification removed from @${user.username}',
                ru: 'Подтверждение снято с @${user.username}',
              ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busyId = null);
      CommsScope.read(context).showSnack(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final verifiedCount = _users.where((u) => u.isVerified).length;
    return Scaffold(
      appBar: AppBar(
        title: Text(L.t('Verified badges', ru: 'Значки подтверждения')),
        actions: [
          IconButton(
            tooltip: L.t('Refresh', ru: 'Обновить'),
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _load(),
              decoration: InputDecoration(
                labelText: L.t('Search users', ru: 'Поиск пользователей'),
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: L.t('Clear', ru: 'Очистить'),
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _search.clear();
                    _load();
                  },
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                L.t(
                  '$verifiedCount of ${_users.length} users verified',
                  ru: 'Подтверждено $verifiedCount из ${_users.length}',
                ),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      itemCount: _users.length,
                      itemBuilder: (context, i) {
                        final user = _users[i];
                        final busy = _busyId == user.id;
                        return Card(
                          margin: const EdgeInsets.symmetric(vertical: 5),
                          child: ListTile(
                            leading: UserAvatar(
                              name: user.displayName,
                              seed: user.username,
                              isVerified: user.isVerified,
                              radius: 20,
                            ),
                            title: Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    user.displayName.isEmpty
                                        ? user.username
                                        : user.displayName,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (user.isVerified) ...[
                                  const SizedBox(width: 4),
                                  const Icon(
                                    Icons.verified,
                                    size: 16,
                                    color: Colors.blueAccent,
                                  ),
                                ],
                              ],
                            ),
                            subtitle: Text(
                              '@${user.username}'
                              '${user.role != 'user' ? ' · ${user.role}' : ''}',
                            ),
                            trailing: busy
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : FilledButton.tonalIcon(
                                    onPressed: () => _toggle(user),
                                    icon: Icon(
                                      user.isVerified
                                          ? Icons.remove_circle_outline
                                          : Icons.verified_outlined,
                                      size: 18,
                                    ),
                                    label: Text(
                                      user.isVerified
                                          ? L.t('Remove', ru: 'Снять')
                                          : L.t('Verify', ru: 'Подтвердить'),
                                    ),
                                  ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
