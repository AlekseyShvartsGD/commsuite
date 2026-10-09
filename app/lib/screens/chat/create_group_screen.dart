import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/api.dart';
import '../../models.dart';
import '../../services/comms_controller.dart';
import '../../widgets/user_avatar.dart';
import 'chat_screen.dart';
import '../../core/localizations.dart';

class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  final _search = TextEditingController();
  final List<User> _selected = [];
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    _search.addListener(_onQuery);
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _search.dispose();
    super.dispose();
  }

  void _onQuery() {
    // The field is read-only; typing opens the picker sheet instead.
    _searchFocus();
  }

  void _toggle(User user, bool add) {
    setState(() {
      if (add) {
        _selected.add(user);
      } else {
        _selected.removeWhere((s) => s.id == user.id);
      }
    });
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      CommsScope.read(context)
          .showSnack(L.t('Give the group a name', ru: 'Дайте группе название'));
      return;
    }
    if (_selected.isEmpty) {
      CommsScope.read(context).showSnack(
        L.t('Add at least one member', ru: 'Добавьте хотя бы одного участника'),
      );
      return;
    }
    setState(() => _creating = true);
    final controller = CommsScope.read(context);
    final conv = await controller.createGroup(
      name: name,
      description: _description.text.trim(),
      memberIds: _selected.map((u) => u.id).toList(),
    );
    if (!mounted) return;
    setState(() => _creating = false);
    if (conv == null) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => ChatScreen(conversation: conv)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final placeholder = _selected.isEmpty
        ? L.t('You', ru: 'Вы')
        : L.t(
            'You, ${_selected.map((u) => u.displayName).take(2).join(', ')}'
            '${_selected.length > 2 ? '…' : ''}',
            ru:
                'Вы, ${_selected.map((u) => u.displayName).take(2).join(', ')}'
                '${_selected.length > 2 ? '…' : ''}',
          );

    return Scaffold(
      appBar: AppBar(title: Text(L.t('New group', ru: 'Новая группа'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            maxLength: 64,
            autofocus: true,
            decoration: InputDecoration(
              labelText: L.t('Group name', ru: 'Название группы'),
              hintText: L.t(
                'e.g. Weekend plans',
                ru: 'напр. Планы на выходные',
              ),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _description,
            maxLines: 2,
            maxLength: 300,
            decoration: InputDecoration(
              labelText: L.t(
                'Description (optional)',
                ru: 'Описание (необязательно)',
              ),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _search,
            readOnly: true,
            onTap: () => _searchFocus(),
            decoration: InputDecoration(
              labelText: L.t(
                'Add members ($placeholder)',
                ru: 'Добавить участников ($placeholder)',
              ),
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
          if (_selected.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final user in _selected)
                  InputChip(
                    avatar: UserAvatar(
                      name: user.displayName,
                      seed: user.username,
                    ),
                    label: Text(user.displayName),
                    onDeleted: () => _toggle(user, false),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            height: 48,
            child: FilledButton.icon(
              onPressed: _creating ? null : _create,
              icon: _creating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.groups),
              label: Text(L.t('Create group', ru: 'Создать группу')),
            ),
          ),
        ],
      ),
    );
  }

  void _searchFocus() {
    final c = CommsScope.read(context);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _SearchPeopleSheet(
        controller: c,
        selectedIds: _selected.map((u) => u.id).toSet(),
        onPick: (user) => _toggle(user, true),
      ),
    );
  }
}

class _SearchPeopleSheet extends StatefulWidget {
  final CommsController controller;
  final Set<String> selectedIds;
  final void Function(User user) onPick;

  const _SearchPeopleSheet({
    required this.controller,
    required this.selectedIds,
    required this.onPick,
  });

  @override
  State<_SearchPeopleSheet> createState() => _SearchPeopleSheetState();
}

class _SearchPeopleSheetState extends State<_SearchPeopleSheet> {
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
        _results = users
            .where((u) => u.id != widget.controller.user?.id)
            .where((u) => !widget.selectedIds.contains(u.id))
            .toList();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
                autofocus: true,
                decoration: InputDecoration(
                  hintText: L.t('Search people…', ru: 'Поиск людей…'),
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
                  : _results.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _search.text.trim().isEmpty
                            ? L.t(
                                'Type a name or username',
                                ru: 'Введите имя или имя пользователя',
                              )
                            : L.t('No one found', ru: 'Никого не найдено'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: _results.length,
                      itemBuilder: (context, index) {
                        final user = _results[index];
                        return ListTile(
                          leading: UserAvatar(
                            name: user.displayName,
                            seed: user.username,
                          ),
                          title: Text(user.displayName),
                          subtitle: Text('@${user.username}'),
                          trailing: const Icon(Icons.add_circle_outline),
                          onTap: () {
                            widget.onPick(user);
                            Navigator.of(context).pop();
                          },
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
