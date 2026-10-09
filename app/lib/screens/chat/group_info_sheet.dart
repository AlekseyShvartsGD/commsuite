import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/api.dart';
import '../../models.dart';
import '../../services/comms_controller.dart';
import '../../widgets/user_avatar.dart';
import '../../core/localizations.dart';

/// Bottom sheet with the group's details, members, and management actions.
class GroupInfoSheet extends StatefulWidget {
  final Conversation conversation;

  const GroupInfoSheet({super.key, required this.conversation});

  @override
  State<GroupInfoSheet> createState() => _GroupInfoSheetState();
}

class _GroupInfoSheetState extends State<GroupInfoSheet> {
  late Conversation _conv = widget.conversation;

  CommsController get _controller => CommsScope.read(context);

  bool get _canManage =>
      _conv.isGroup && (_conv.myRole == 'owner' || _conv.myRole == 'admin');

  late final String _myId = _controller.user?.id ?? '';

  void setConversation(Conversation c) => setState(() => _conv = c);

  Future<void> _editDetails() async {
    final nameController = TextEditingController(text: _conv.name);
    final descController = TextEditingController(text: _conv.description);
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(L.t('Edit group', ru: 'Редактировать группу')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              maxLength: 64,
              decoration: InputDecoration(
                labelText: L.t('Group name', ru: 'Название группы'),
                border: const OutlineInputBorder(),
              ),
            ),
            TextField(
              controller: descController,
              maxLines: 3,
              maxLength: 300,
              decoration: InputDecoration(
                labelText: L.t(
                  'Description (optional)',
                  ru: 'Описание (необязательно)',
                ),
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(L.t('Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            onPressed: () {
              final name = nameController.text.trim();
              if (name.isEmpty) {
                _controller.showSnack(
                  L.t(
                    'Group name cannot be empty',
                    ru: 'Название группы не может быть пустым',
                  ),
                );
                return;
              }
              Navigator.of(context).pop((name, descController.text.trim()));
            },
            child: Text(L.t('Save', ru: 'Сохранить')),
          ),
        ],
      ),
    );
    if (result == null || !mounted) return;
    final updated = await _controller.updateGroup(
      _conv,
      name: result.$1,
      description: result.$2,
    );
    if (updated != null && mounted) setConversation(updated);
  }

  Future<void> _addMember() async {
    final token = _controller.token;
    if (token == null) return;
    final picked = await showModalBottomSheet<User>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _MemberPicker(
        controller: _controller,
        memberIds: _conv.members.map((m) => m.user.id).toSet(),
      ),
    );
    if (picked == null || !mounted) return;
    final updated = await _controller.addGroupMember(_conv, picked.id);
    if (updated != null && mounted) setConversation(updated);
  }

  Future<void> _changeRole(GroupMember m, String role) async {
    final updated = await _controller.setGroupMemberRole(
      _conv,
      m.user.id,
      role,
    );
    if (updated != null && mounted) setConversation(updated);
  }

  Future<void> _confirmRemove(GroupMember m) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          L.t(
            'Remove ${m.user.displayName}?',
            ru: 'Удалить ${m.user.displayName}?',
          ),
        ),
        content: Text(
          L.t(
            'They can be added back at any time.',
            ru: 'Участника можно добавить обратно в любое время.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(L.t('Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: Text(L.t('Remove', ru: 'Удалить')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _controller.removeGroupMember(_conv, m.user.id);
    final fresh = _controller.conversationById(_conv.id);
    if (fresh != null && mounted) setConversation(fresh);
  }

  Future<void> _leave() async {
    final nav = Navigator.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(L.t('Leave group?', ru: 'Покинуть группу?')),
        content: Text(
          _conv.myRole == 'owner'
              ? L.t(
                  'As the owner, leaving transfers ownership to another member. If you are the only member the group is deleted.',
                  ru: 'Как владелец, при выходе вы передадите права владельца другому участнику. Если вы единственный участник, группа будет удалена.',
                )
              : L.t(
                  'You will stop receiving messages from this group.',
                  ru: 'Вы перестанете получать сообщения от этой группы.',
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(L.t('Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(L.t('Leave', ru: 'Покинуть')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _controller.removeGroupMember(_conv, _myId);
    nav.pop();
    if (_controller.conversationById(_conv.id) == null) nav.pop();
  }

  Future<void> _delete() async {
    final nav = Navigator.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(L.t('Delete group?', ru: 'Удалить группу?')),
        content: Text(
          L.t(
            'All messages are deleted from the server for every member. This cannot be undone.',
            ru: 'Все сообщения удаляются с сервера для каждого участника. Это действие нельзя отменить.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(L.t('Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: Text(L.t('Delete', ru: 'Удалить')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _controller.deleteGroup(_conv);
    nav.pop();
    nav.pop();
  }

  void _toggleMute(bool value) async {
    final updated = await _controller.setGroupMuted(_conv, value);
    if (updated != null && mounted) setConversation(updated);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.9,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (context, scrollController) => ListView(
          controller: scrollController,
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
              child: Column(
                children: [
                  UserAvatar(name: _conv.title, seed: _conv.id, radius: 34),
                  const SizedBox(height: 10),
                  Text(
                    _conv.title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (_conv.description.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      _conv.description,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    L.plural(
                      _conv.members.length,
                      enOne: '1 member',
                      enMany: '${_conv.members.length} members',
                      ruOne: '${_conv.members.length} участник',
                      ruFew: '${_conv.members.length} участника',
                      ruMany: '${_conv.members.length} участников',
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              secondary: Icon(
                _conv.muted
                    ? Icons.notifications_off_outlined
                    : Icons.notifications_outlined,
              ),
              title: Text(
                L.t('Mute notifications', ru: 'Отключить уведомления'),
              ),
              value: _conv.muted,
              onChanged: _toggleMute,
            ),
            if (_canManage) ...[
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Text(
                  L.t(
                    'Edit name & description',
                    ru: 'Изменить название и описание',
                  ),
                ),
                onTap: _editDetails,
              ),
              ListTile(
                leading: const Icon(Icons.person_add_alt),
                title: Text(L.t('Add member', ru: 'Добавить участника')),
                onTap: _addMember,
              ),
            ],
            const Divider(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                L.t(
                  'Members — ${_conv.members.length}',
                  ru: 'Участники — ${_conv.members.length}',
                ),
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            for (final m in _conv.members) _memberTile(m),
            const Divider(height: 24),
            ListTile(
              leading: const Icon(Icons.logout, color: Colors.red),
              title: Text(
                L.t('Leave group', ru: 'Покинуть группу'),
                style: const TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.w600,
                ),
              ),
              onTap: _leave,
            ),
            if (_conv.myRole == 'owner')
              ListTile(
                leading: const Icon(Icons.delete_forever, color: Colors.red),
                title: Text(
                  L.t('Delete group', ru: 'Удалить группу'),
                  style: const TextStyle(
                    color: Colors.red,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onTap: _delete,
              ),
          ],
        ),
      ),
    );
  }

  Widget _memberTile(GroupMember m) {
    final theme = Theme.of(context);
    final isSelf = m.user.id == _myId;
    final isAdmin = m.isAdmin;
    final canManageRoles = _conv.myRole == 'owner' && !isSelf;
    final canRemove =
        !isSelf &&
        (_conv.myRole == 'owner' ||
            (_conv.myRole == 'admin' && m.role == 'member'));

    String roleLabel(String role) => role == 'owner'
        ? L.t('OWNER', ru: 'ВЛАДЕЛЕЦ')
        : (role == 'admin'
              ? L.t('ADMIN', ru: 'АДМИНИСТРАТОР')
              : L.t('GROUP MEMBER', ru: 'УЧАСТНИК ГРУППЫ'));

    return ListTile(
      leading: UserAvatar(
        name: m.user.displayName,
        seed: m.user.username,
        radius: 20,
      ),
      title: Text(
        isSelf
            ? L.t(
                '${m.user.displayName} (you)',
                ru: '${m.user.displayName} (вы)',
              )
            : m.user.displayName,
      ),
      subtitle: Text(
        '@${m.user.username} · ${roleLabel(m.role)}',
        style: theme.textTheme.bodySmall,
      ),
      trailing: (canManageRoles || canRemove)
          ? PopupMenuButton<String>(
              onSelected: (action) async {
                switch (action) {
                  case 'promote':
                    await _changeRole(m, 'admin');
                    break;
                  case 'demote':
                    await _changeRole(m, 'member');
                    break;
                  case 'remove':
                    await _confirmRemove(m);
                    break;
                }
              },
              itemBuilder: (context) => [
                if (canManageRoles && !isAdmin)
                  PopupMenuItem(
                    value: 'promote',
                    child: Text(
                      L.t('Promote to admin', ru: 'Повысить до администратора'),
                    ),
                  ),
                if (canManageRoles && m.role == 'admin')
                  PopupMenuItem(
                    value: 'demote',
                    child: Text(
                      L.t('Demote to member', ru: 'Разжаловать до участника'),
                    ),
                  ),
                if (canRemove)
                  PopupMenuItem(
                    value: 'remove',
                    child: Text(
                      L.t('Remove from group', ru: 'Удалить из группы'),
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
              ],
            )
          : Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                roleLabel(m.role),
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
            ),
    );
  }
}

class _MemberPicker extends StatefulWidget {
  final CommsController controller;
  final Set<String> memberIds;

  const _MemberPicker({required this.controller, required this.memberIds});

  @override
  State<_MemberPicker> createState() => _MemberPickerState();
}

class _MemberPickerState extends State<_MemberPicker> {
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
    _load(query: _search.text.trim());
  }

  Future<void> _load({String query = ''}) async {
    final token = widget.controller.token;
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

  @override
  Widget build(BuildContext context) {
    final filtered = _results
        .where((u) => u.id != widget.controller.user?.id)
        .where((u) => !widget.memberIds.contains(u.id))
        .toList();
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: _search,
                decoration: InputDecoration(
                  hintText: L.t(
                    'Search users to add…',
                    ru: 'Поиск пользователей для добавления…',
                  ),
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(28),
                  ),
                ),
              ),
            ),
            Flexible(
              child: _loading
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(),
                    )
                  : filtered.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        L.t(
                          'No new users to add',
                          ru: 'Нет новых пользователей',
                        ),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final user = filtered[index];
                        return ListTile(
                          leading: UserAvatar(
                            name: user.displayName,
                            seed: user.username,
                          ),
                          title: Text(user.displayName),
                          subtitle: Text('@${user.username}'),
                          onTap: () => Navigator.of(context).pop(user),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
