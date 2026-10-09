import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/api.dart';
import '../../models.dart';
import '../../widgets/user_avatar.dart';
import '../call/call_screen.dart';
import '../chat/chat_screen.dart';
import '../../core/localizations.dart';

class ProfileScreen extends StatefulWidget {
  final User peer;
  final Conversation? conversation;

  const ProfileScreen({super.key, required this.peer, this.conversation});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late User _user;

  bool get _isSelf => _user.id == CommsScope.read(context).user?.id;

  @override
  void initState() {
    super.initState();
    _user = widget.peer;
    _refreshUser();
  }

  Future<void> _refreshUser() async {
    final token = CommsScope.read(context).token;
    if (token == null) return;
    try {
      final fresh = await Api.user(token, _user.id);
      if (!mounted) return;
      setState(() => _user = fresh);
    } on ApiException {
      // stale view is fine; local copy may be older
    }
  }

  Future<void> _call(bool video) async {
    final controller = CommsScope.read(context);
    final ok = await controller.startCall(_user, video: video);
    if (ok && mounted) {
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const CallScreen()));
    }
  }

  Future<void> _message() async {
    final controller = CommsScope.read(context);
    final conv = await controller.openConversation(_user);
    if (!mounted || conv == null) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => ChatScreen(conversation: conv)),
    );
  }

  Future<void> _confirmBlockUnblock() async {
    final controller = CommsScope.read(context);
    final blocked = controller.isBlocked(_user.id);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          blocked
              ? L.t(
                  'Unblock ${_user.displayName}?',
                  ru: 'Разблокировать ${_user.displayName}?',
                )
              : L.t(
                  'Block ${_user.displayName}?',
                  ru: 'Заблокировать ${_user.displayName}?',
                ),
        ),
        content: Text(
          blocked
              ? L.t(
                  'They will be able to message and call you again.',
                  ru: 'Они снова смогут писать и звонить вам.',
                )
              : L.t(
                  'Blocked users cannot message or call you, and their messages to you are rejected.',
                  ru: 'Заблокированные пользователи не могут писать или звонить вам, а их сообщения отклоняются.',
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(L.t('Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              blocked
                  ? L.t('Unblock', ru: 'Разблокировать')
                  : L.t('Block', ru: 'Заблокировать'),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      if (blocked) {
        await controller.unblockUser(_user);
      } else {
        await controller.blockUser(_user);
      }
    }
  }

  Future<void> _confirmReport() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.report_gmailerrorred, color: Colors.red),
        title: Text(L.t('Report user?', ru: 'Пожаловаться на пользователя?')),
        content: Text(
          L.t(
            'Report ${_user.displayName} for abusive or harmful behaviour. Reports are logged on the server for a moderator to review.',
            ru: 'Пожаловаться на ${_user.displayName} за оскорбительное или вредное поведение. Жалобы фиксируются на сервере для проверки модератором.',
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
            child: Text(L.t('Report', ru: 'Пожаловаться')),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await CommsScope.read(context).reportUser(_user);
    }
  }

  Future<void> _confirmClearChat() async {
    final conv = widget.conversation;
    if (conv == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          L.t(
            'Clear chat with ${_user.displayName}?',
            ru: 'Очистить чат с ${_user.displayName}?',
          ),
        ),
        content: Text(
          L.t(
            'This deletes the message history from the server for both of you. It cannot be undone.',
            ru: 'Это удалит историю сообщений с сервера для вас обоих. Действие нельзя отменить.',
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
            child: Text(L.t('Clear', ru: 'Очистить')),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await CommsScope.read(context).clearChat(conv);
    }
  }

  Future<void> _editBio() async {
    final controller = CommsScope.read(context);
    final text = TextEditingController(text: _user.bio);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(L.t('About', ru: 'О себе')),
        content: TextField(
          controller: text,
          maxLines: 3,
          maxLength: 300,
          decoration: InputDecoration(
            hintText: L.t('What\u2019s on your mind?', ru: 'О чём вы думаете?'),
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(L.t('Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(text.text.trim()),
            child: Text(L.t('Save', ru: 'Сохранить')),
          ),
        ],
      ),
    );
    if (result != null && mounted && result != controller.user?.bio) {
      await controller.updateBio(result);
      if (mounted) setState(() => _user = _user.copyWith(bio: result));
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = CommsScope.of(context);
    final theme = Theme.of(context);
    final blocked = controller.isBlocked(_user.id);
    final online = controller.isOnline(_user.id);

    return Scaffold(
      appBar: AppBar(title: Text(L.t('Profile', ru: 'Профиль'))),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 24),
        children: [
          Center(
            child: UserAvatar(
              name: _user.displayName,
              seed: _user.username,
              showOnline: online,
              radius: 52,
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              _user.displayName,
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              '@${_user.username}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Center(
            child: Text(
              online
                  ? L.t('online', ru: 'В сети')
                  : L.t('offline', ru: 'Не в сети'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: online
                    ? Colors.green
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (blocked) ...[
            const SizedBox(height: 12),
            Center(
              child: Chip(
                avatar: const Icon(Icons.block, size: 16),
                label: Text(L.t('Blocked', ru: 'Заблокирован')),
                backgroundColor: theme.colorScheme.errorContainer,
                labelStyle: TextStyle(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
          if (!_isSelf)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _ActionButton(
                  icon: Icons.chat_bubble_outline,
                  label: L.t('Message', ru: 'Сообщение'),
                  onTap: _message,
                ),
                _ActionButton(
                  icon: Icons.call,
                  label: L.t('Call', ru: 'Звонок'),
                  onTap: () => _call(false),
                ),
                _ActionButton(
                  icon: Icons.videocam_outlined,
                  label: L.t('Video', ru: 'Видео'),
                  onTap: () => _call(true),
                ),
              ],
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: FilledButton.tonalIcon(
                onPressed: _editBio,
                icon: const Icon(Icons.edit),
                label: Text(L.t('Edit my bio', ru: 'Изменить о себе')),
              ),
            ),
          const SizedBox(height: 24),
          ListTile(
            leading: _isSelf
                ? const Icon(Icons.edit)
                : const Icon(Icons.info_outline),
            title: Text(
              _isSelf
                  ? L.t('My bio', ru: 'О себе')
                  : L.t('About', ru: 'О себе'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              _user.bio.isEmpty
                  ? L.t(
                      'Hey there! I am using Commsuite.',
                      ru: 'Привет! Я использую Commsuite.',
                    )
                  : _user.bio,
              style: const TextStyle(fontStyle: FontStyle.italic),
            ),
            onTap: _isSelf ? _editBio : null,
          ),
          const Divider(),
          if (!_isSelf) ...[
            ListTile(
              leading: Icon(
                blocked ? Icons.person_off_outlined : Icons.block_outlined,
                color: Colors.red,
              ),
              title: Text(
                blocked
                    ? L.t(
                        'Unblock ${_user.displayName}',
                        ru: 'Разблокировать ${_user.displayName}',
                      )
                    : L.t(
                        'Block ${_user.displayName}',
                        ru: 'Заблокировать ${_user.displayName}',
                      ),
                style: const TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.w600,
                ),
              ),
              onTap: _confirmBlockUnblock,
            ),
            ListTile(
              leading: const Icon(
                Icons.report_gmailerrorred,
                color: Colors.red,
              ),
              title: Text(
                L.t(
                  'Report ${_user.displayName}',
                  ru: 'Пожаловаться на ${_user.displayName}',
                ),
                style: const TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.w600,
                ),
              ),
              onTap: _confirmReport,
            ),
            if (widget.conversation != null)
              ListTile(
                leading: const Icon(Icons.delete_sweep_outlined),
                title: Text(L.t('Clear chat', ru: 'Очистить чат')),
                onTap: _confirmClearChat,
              ),
          ],
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: theme.colorScheme.secondaryContainer,
              child: Icon(icon, color: theme.colorScheme.onSecondaryContainer),
            ),
            const SizedBox(height: 6),
            Text(label, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
