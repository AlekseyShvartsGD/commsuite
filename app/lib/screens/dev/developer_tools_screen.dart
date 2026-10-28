import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app.dart';
import '../../core/api.dart';
import '../../core/app_config.dart';
import '../../core/localizations.dart';
import '../../models.dart';
import '../../widgets/user_avatar.dart';
import '../chat/chat_screen.dart';

/// Developer tools: automated accounts ("bots") and the mini-apps hosted by
/// them. A bot is a real user on the server, so it shows up in People and can
/// be added to conversations and groups like anyone else.
class DeveloperToolsScreen extends StatefulWidget {
  const DeveloperToolsScreen({super.key});

  @override
  State<DeveloperToolsScreen> createState() => _DeveloperToolsScreenState();
}

class _DeveloperToolsScreenState extends State<DeveloperToolsScreen> {
  List<Bot> _bots = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final token = CommsScope.read(context).token;
    if (token == null) {
      setState(() {
        _loading = false;
        _error = L.t('Sign in to manage your bots.', ru: 'Войдите, чтобы управлять ботами.');
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final bots = await Api.bots(token);
      if (!mounted) return;
      setState(() {
        _bots = bots;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  void _replace(Bot bot) {
    if (!mounted) return;
    setState(() {
      final index = _bots.indexWhere((b) => b.user.id == bot.user.id);
      if (index >= 0) {
        _bots = [..._bots]..[index] = bot;
      } else {
        _bots = [bot, ..._bots];
      }
    });
  }

  Future<void> _create() async {
    final token = CommsScope.read(context).token;
    if (token == null) return;
    final draft = await showDialog<_BotDraft>(
      context: context,
      builder: (_) => const _BotDialog(),
    );
    if (draft == null || !mounted) return;
    try {
      final bot = await Api.createBot(
        token,
        name: draft.name,
        description: draft.description,
        miniApp: draft.miniApp,
        mode: draft.mode,
      );
      if (!mounted) return;
      _replace(bot);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.t(
              'Created @${bot.user.username}. Find it in People and start chatting.',
              ru: 'Создан @${bot.user.username}. Найдите его в контактах и начните чат.',
            ),
          ),
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      _showError(e.message);
    }
  }

  Future<void> _edit(Bot bot) async {
    final token = CommsScope.read(context).token;
    if (token == null) return;
    final draft = await showDialog<_BotDraft>(
      context: context,
      builder: (_) => _BotDialog(bot: bot),
    );
    if (draft == null || !mounted) return;
    try {
      final updated = await Api.updateBot(
        token,
        bot.user.id,
        name: draft.name,
        description: draft.description,
        miniApp: draft.miniApp,
        mode: draft.mode,
      );
      _replace(updated);
    } on ApiException catch (e) {
      if (!mounted) return;
      _showError(e.message);
    }
  }

  Future<void> _toggle(Bot bot, bool enabled) async {
    final token = CommsScope.read(context).token;
    if (token == null) return;
    try {
      final updated = await Api.updateBot(token, bot.user.id, enabled: enabled);
      _replace(updated);
    } on ApiException catch (e) {
      if (!mounted) return;
      _showError(e.message);
    }
  }

  Future<void> _delete(Bot bot) async {
    final token = CommsScope.read(context).token;
    if (token == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(L.t('Delete bot?', ru: 'Удалить бота?')),
        content: Text(
          L.t(
            'The account @${bot.user.username} will be removed, including its chats and replies. This cannot be undone.',
            ru: 'Аккаунт @${bot.user.username} будет удалён вместе с чатами и ответами. Действие нельзя отменить.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(L.t('Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(L.t('Delete', ru: 'Удалить')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await Api.deleteBot(token, bot.user.id);
      if (!mounted) return;
      setState(() {
        _bots = _bots.where((b) => b.user.id != bot.user.id).toList();
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      _showError(e.message);
    }
  }

  Future<void> _openChat(Bot bot) async {
    final controller = CommsScope.read(context);
    final conv = await controller.openConversation(bot.user);
    if (!mounted || conv == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ChatScreen(conversation: conv)),
    );
  }

  Future<void> _manageReplies(Bot bot) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _BotRepliesScreen(bot: bot, onUpdated: _replace),
      ),
    );
  }

  Future<void> _showApi(Bot bot) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _BotApiDialog(bot: bot, onUpdated: _replace),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(L.t('Developer tools', ru: 'Инструменты разработчика')),
        actions: [
          IconButton(
            tooltip: L.t('Refresh', ru: 'Обновить'),
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loading ? null : _create,
        icon: const Icon(Icons.smart_toy_outlined),
        label: Text(L.t('New bot', ru: 'Новый бот')),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                Text(
                  L.t('Chat bots', ru: 'Чат-боты'),
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  L.t(
                    'A bot is a separate Commsuite account that behaves automatically. '
                    'It appears in People and can be added to groups. Program it in '
                    'Python through the bot API, or use the built-in replies and mini-apps.',
                    ru: 'Бот — это отдельный аккаунт Commsuite, который ведёт себя автоматически. '
                        'Он отображается в контактах, его можно добавлять в группы. '
                        'Программируйте его на Python через Bot API или используйте '
                        'встроенные ответы и мини-приложения.',
                  ),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
                const SizedBox(height: 12),
                if (_error != null)
                  Card(
                    color: theme.colorScheme.errorContainer,
                    child: ListTile(
                      leading: Icon(
                        Icons.cloud_off,
                        color: theme.colorScheme.onErrorContainer,
                      ),
                      title: Text(
                        _error!,
                        style: TextStyle(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                      trailing: TextButton(
                        onPressed: _load,
                        child: Text(L.t('Retry', ru: 'Повторить')),
                      ),
                    ),
                  )
                else if (_bots.isEmpty)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.smart_toy_outlined),
                      title: Text(L.t('No bots yet', ru: 'Ботов пока нет')),
                      subtitle: Text(
                        L.t(
                          'Create one with the button below.',
                          ru: 'Создайте первого кнопкой ниже.',
                        ),
                      ),
                    ),
                  )
                else
                  for (final bot in _bots)
                    _BotCard(
                      bot: bot,
                      onOpenChat: () => _openChat(bot),
                      onEdit: () => _edit(bot),
                      onReplies: () => _manageReplies(bot),
                      onApi: () => _showApi(bot),
                      onDelete: () => _delete(bot),
                      onToggle: (value) => _toggle(bot, value),
                    ),
                const SizedBox(height: 24),
                Text(
                  L.t('Mini-apps', ru: 'Мини-приложения'),
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  L.t(
                    'Mini-apps live inside a built-in bot. Pick one when you create or edit '
                    'a built-in bot, then message the bot to run it.',
                    ru: 'Мини-приложения живут внутри встроенного бота. Выберите его при '
                        'создании или редактировании встроенного бота, затем напишите боту, '
                        'чтобы запустить.',
                  ),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
                const SizedBox(height: 8),
                const _MiniAppCard(
                  icon: Icons.data_object,
                  title: 'JSON formatter',
                  ruTitle: 'Форматирование JSON',
                  description:
                      'Send a JSON object or array and the bot pretty-prints it.',
                  ruDescription:
                      'Отправьте JSON-объект или массив, и бот отформатирует его.',
                  commands: ['{"hello":"world"}', '/json {"a":1}'],
                ),
                const _MiniAppCard(
                  icon: Icons.code,
                  title: 'Base64',
                  ruTitle: 'Base64',
                  description:
                      'Encode text with /b64 and decode it with /unb64.',
                  ruDescription:
                      'Кодируйте текст командой /b64 и декодируйте командой /unb64.',
                  commands: ['/b64 hello', '/unb64 aGVsbG8='],
                ),
                const _MiniAppCard(
                  icon: Icons.fingerprint,
                  title: 'UUID generator',
                  ruTitle: 'Генератор UUID',
                  description:
                      'Generate random v4 identifiers, five by default.',
                  ruDescription:
                      'Генерирует случайные идентификаторы v4, по умолчанию пять.',
                  commands: ['/uuid', '/uuid 3'],
                ),
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.help_outline),
                    title: Text(L.t('Ask a bot for help', ru: 'Спросите бота о помощи')),
                    subtitle: Text(
                      L.t(
                        'Send /help to any bot to see its commands and replies.',
                        ru: 'Отправьте /help любому боту, чтобы увидеть его команды и ответы.',
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _BotCard extends StatelessWidget {
  final Bot bot;
  final VoidCallback onOpenChat;
  final VoidCallback onEdit;
  final VoidCallback onReplies;
  final VoidCallback onApi;
  final VoidCallback onDelete;
  final ValueChanged<bool> onToggle;

  const _BotCard({
    required this.bot,
    required this.onOpenChat,
    required this.onEdit,
    required this.onReplies,
    required this.onApi,
    required this.onDelete,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final description = bot.description.isEmpty
        ? L.t('No description yet.', ru: 'Описание пока не задано.')
        : bot.description;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: UserAvatar(
              name: bot.user.displayName,
              seed: bot.user.username,
              isVerified: bot.user.isVerified,
              radius: 24,
            ),
            title: Row(
              children: [
                Flexible(
                  child: Text(
                    bot.user.displayName,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'BOT',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ),
            subtitle: Text('@${bot.user.username}'),
            trailing: Switch(
              value: bot.enabled,
              onChanged: onToggle,
            ),
            onTap: onOpenChat,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  description,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    Chip(
                      avatar: Icon(
                        bot.isExternal ? Icons.code : Icons.widgets_outlined,
                        size: 16,
                      ),
                      label: Text(
                        bot.isExternal
                            ? L.t('External API', ru: 'Внешний API')
                            : (bot.miniApp == 'none'
                                ? L.t('Built-in replies', ru: 'Встроенные ответы')
                                : bot.miniAppLabel),
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                    Chip(
                      avatar: const Icon(Icons.bolt_outlined, size: 16),
                      label: Text(
                        L.t(
                          '${bot.replies.length} replies',
                          ru: 'Ответов: ${bot.replies.length}',
                        ),
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                    Chip(
                      avatar: Icon(
                        bot.enabled ? Icons.check_circle_outline : Icons.pause_circle_outline,
                        size: 16,
                      ),
                      label: Text(
                        bot.enabled
                            ? L.t('Active', ru: 'Активен')
                            : L.t('Paused', ru: 'На паузе'),
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton.icon(
                  onPressed: onOpenChat,
                  icon: const Icon(Icons.chat_bubble_outline, size: 18),
                  label: Text(L.t('Chat', ru: 'Чат')),
                ),
                TextButton.icon(
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: Text(L.t('Edit', ru: 'Изменить')),
                ),
                TextButton.icon(
                  onPressed: onReplies,
                  icon: const Icon(Icons.bolt_outlined, size: 18),
                  label: Text(L.t('Replies', ru: 'Ответы')),
                ),
                TextButton.icon(
                  onPressed: onApi,
                  icon: const Icon(Icons.code, size: 18),
                  label: Text(L.t('API', ru: 'API')),
                ),
                IconButton(
                  tooltip: L.t('Delete bot', ru: 'Удалить бота'),
                  onPressed: onDelete,
                  icon: Icon(
                    Icons.delete_outline,
                    color: theme.colorScheme.error,
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

class _MiniAppCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String ruTitle;
  final String description;
  final String ruDescription;
  final List<String> commands;

  const _MiniAppCard({
    required this.icon,
    required this.title,
    required this.ruTitle,
    required this.description,
    required this.ruDescription,
    required this.commands,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    L.t(title, ru: ruTitle),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    L.t(description, ru: ruDescription),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final command in commands)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            command,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BotApiDialog extends StatefulWidget {
  final Bot bot;
  final ValueChanged<Bot> onUpdated;

  const _BotApiDialog({required this.bot, required this.onUpdated});

  @override
  State<_BotApiDialog> createState() => _BotApiDialogState();
}

class _BotApiDialogState extends State<_BotApiDialog> {
  late Bot _bot = widget.bot;
  bool _busy = false;

  String get _pythonExample {
    final base = AppConfig.apiBase;
    return '''
import json, urllib.request

BASE = "$base"
TOKEN = "${_bot.token}"
OFFSET = 0

def api(path, data=None):
    req = urllib.request.Request(
        BASE + path,
        data=None if data is None else json.dumps(data).encode(),
        headers={"Authorization": f"Bearer {TOKEN}",
                 "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)

while True:
    for u in api(f"/bot/updates?offset={OFFSET}&timeout=30")["updates"]:
        OFFSET = u["updateId"]
        text = u["message"].get("body") or ""
        api("/bot/sendMessage", {
            "conversationId": u["conversationId"],
            "text": f"echo: {text}",
        })
''';
  }

  Future<void> _copy(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(label)));
  }

  Future<void> _reset() async {
    final token = CommsScope.read(context).token;
    if (token == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(L.t('Reset token?', ru: 'Сбросить токен?')),
        content: Text(
          L.t(
            'The current token stops working immediately. Update any running bot scripts with the new token.',
            ru: 'Текущий токен сразу перестанет работать. Обновите токен в запущенных скриптах бота.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(L.t('Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(L.t('Reset', ru: 'Сбросить')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final updated = await Api.resetBotToken(token, _bot.user.id);
      if (!mounted) return;
      setState(() {
        _bot = updated;
        _busy = false;
      });
      widget.onUpdated(updated);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final codeStyle = TextStyle(
      fontFamily: 'monospace',
      fontSize: 12,
      color: theme.colorScheme.onSurface,
    );
    Widget box(String text) => Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(text, style: codeStyle),
        );

    return AlertDialog(
      title: Text(
        L.t('Bot API · @${_bot.user.username}',
            ru: 'Bot API · @${_bot.user.username}'),
      ),
      content: SizedBox(
        width: 580,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                L.t(
                  'Use this token to control the bot from your own program. A bot can call the regular user API and the three bot endpoints below.',
                  ru: 'Используйте этот токен, чтобы управлять ботом из своей программы. Бот может вызывать обычный API и три эндпоинта ниже.',
                ),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
              const SizedBox(height: 8),
              Text(
                L.t('API token', ru: 'Токен API'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              box(_bot.token),
              const SizedBox(height: 4),
              Wrap(
                spacing: 4,
                children: [
                  TextButton.icon(
                    onPressed: () => _copy(
                      _bot.token,
                      L.t('Token copied', ru: 'Токен скопирован'),
                    ),
                    icon: const Icon(Icons.copy, size: 18),
                    label: Text(L.t('Copy token', ru: 'Копировать токен')),
                  ),
                  TextButton.icon(
                    onPressed: _busy ? null : _reset,
                    icon: const Icon(Icons.autorenew, size: 18),
                    label: Text(L.t('Reset token', ru: 'Сбросить токен')),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                L.t('Endpoints', ru: 'Эндпоинты'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              box(
                'GET  /api/bot/me\n'
                'GET  /api/bot/updates?offset=<id>&timeout=30\n'
                'POST /api/bot/sendMessage\n'
                '     {"conversationId": "…", "text": "hello"}',
              ),
              const SizedBox(height: 8),
              Text(
                L.t('Python echo bot', ru: 'Эхо-бот на Python'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              box(_pythonExample),
              const SizedBox(height: 8),
              Text(
                L.t(
                  'Pass the token as "Authorization: Bearer <token>". Updates are acknowledged when you pass the last update id as offset. Paused bots reject their token.',
                  ru: 'Передавайте токен в "Authorization: Bearer <token>". Обновления подтверждаются, когда вы передаёте id последнего обновления как offset. У приостановленных ботов токен не работает.',
                ),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(L.t('Close', ru: 'Закрыть')),
        ),
        FilledButton.icon(
          onPressed: () => _copy(
            _pythonExample,
            L.t('Python example copied', ru: 'Пример на Python скопирован'),
          ),
          icon: const Icon(Icons.code, size: 18),
          label: Text(L.t('Copy Python', ru: 'Копировать Python')),
        ),
      ],
    );
  }
}

class _BotDraft {
  final String name;
  final String description;
  final String miniApp;
  final String mode;

  const _BotDraft({
    required this.name,
    required this.description,
    required this.miniApp,
    required this.mode,
  });
}

class _BotDialog extends StatefulWidget {
  final Bot? bot;

  const _BotDialog({this.bot});

  @override
  State<_BotDialog> createState() => _BotDialogState();
}

class _BotDialogState extends State<_BotDialog> {
  late final TextEditingController _name;
  late final TextEditingController _description;
  late String _miniApp;
  late String _mode;
  String? _error;

  static const _miniApps = <String>['none', 'json', 'base64', 'uuid'];

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.bot?.user.displayName ?? '');
    _description = TextEditingController(text: widget.bot?.description ?? '');
    _miniApp = widget.bot?.miniApp ?? 'none';
    _mode = widget.bot?.mode ?? 'api';
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = L.t(
            'A bot name is required.',
            ru: 'Название бота обязательно.',
          ));
      return;
    }
    Navigator.of(context).pop(
      _BotDraft(
        name: name,
        description: _description.text.trim(),
        miniApp: _miniApp,
        mode: _mode,
      ),
    );
  }

  String _miniAppLabel(String value) => switch (value) {
        'json' => L.t('JSON formatter', ru: 'Форматирование JSON'),
        'base64' => 'Base64',
        'uuid' => L.t('UUID generator', ru: 'Генератор UUID'),
        _ => L.t('None', ru: 'Нет'),
      };

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.bot == null
            ? L.t('New chat bot', ru: 'Новый чат-бот')
            : L.t('Edit chat bot', ru: 'Изменить чат-бота'),
      ),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                maxLength: 48,
                decoration: InputDecoration(
                  labelText: L.t('Bot name', ru: 'Имя бота'),
                  hintText: 'Ping bot',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 4),
              TextField(
                controller: _description,
                maxLength: 300,
                minLines: 2,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: L.t('Description', ru: 'Описание'),
                  hintText: L.t(
                    'What does this bot do?',
                    ru: 'Что делает этот бот?',
                  ),
                  alignLabelWithHint: true,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _mode,
                decoration: InputDecoration(
                  labelText: L.t('How does it answer?', ru: 'Как бот отвечает?'),
                  border: const OutlineInputBorder(),
                ),
                items: [
                  DropdownMenuItem(
                    value: 'api',
                    child: Text(
                      L.t('External program (Python / API)',
                          ru: 'Внешняя программа (Python / API)'),
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'builtin',
                    child: Text(
                      L.t('Built-in replies and mini-app',
                          ru: 'Встроенные ответы и мини-приложение'),
                    ),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _mode = value);
                },
              ),
              if (_mode == 'builtin') ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _miniApp,
                  decoration: InputDecoration(
                    labelText: L.t('Mini-app inside the bot', ru: 'Мини-приложение в боте'),
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    for (final value in _miniApps)
                      DropdownMenuItem(
                        value: value,
                        child: Text(_miniAppLabel(value)),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _miniApp = value);
                  },
                ),
              ],
              const SizedBox(height: 8),
              Text(
                _mode == 'api'
                    ? L.t(
                        'Open API on the bot card to copy its token and a Python example. External programs answer through /api/bot/updates.',
                        ru: 'Откройте API на карточке бота, чтобы скопировать токен и пример на Python. Внешние программы отвечают через /api/bot/updates.',
                      )
                    : L.t(
                        'Built-in mode answers with keyword replies and the selected mini-app. No external program is needed.',
                        ru: 'Встроенный режим отвечает по ключевым словам и выбранному мини-приложению. Внешняя программа не нужна.',
                      ),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                widget.bot == null
                    ? L.t(
                        'A new account is created automatically. You can find it in People and add it to groups. Bots cannot sign in.',
                        ru: 'Новый аккаунт создаётся автоматически. Его можно найти в контактах и добавлять в группы. Боты не могут входить в аккаунт.',
                      )
                    : L.t(
                        'The username @${widget.bot!.user.username} stays the same.',
                        ru: 'Имя пользователя @${widget.bot!.user.username} не меняется.',
                      ),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(L.t('Cancel', ru: 'Отмена')),
        ),
        FilledButton(
          onPressed: _save,
          child: Text(L.t('Save', ru: 'Сохранить')),
        ),
      ],
    );
  }
}

class _BotRepliesScreen extends StatefulWidget {
  final Bot bot;
  final ValueChanged<Bot> onUpdated;

  const _BotRepliesScreen({required this.bot, required this.onUpdated});

  @override
  State<_BotRepliesScreen> createState() => _BotRepliesScreenState();
}

class _BotRepliesScreenState extends State<_BotRepliesScreen> {
  late List<BotReply> _replies = List.of(widget.bot.replies);
  bool _busy = false;

  void _apply(Bot bot) {
    if (!mounted) return;
    setState(() => _replies = List.of(bot.replies));
    widget.onUpdated(bot);
  }

  Future<void> _add() async {
    final token = CommsScope.read(context).token;
    if (token == null) return;
    final rule = await showDialog<BotReply>(
      context: context,
      builder: (_) => const _ReplyDialog(),
    );
    if (rule == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final bot = await Api.addBotReply(
        token,
        widget.bot.user.id,
        trigger: rule.trigger,
        reply: rule.reply,
      );
      _apply(bot);
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(BotReply rule) async {
    final token = CommsScope.read(context).token;
    if (token == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(L.t('Delete reply?', ru: 'Удалить ответ?')),
        content: Text(
          L.t(
            'Messages containing “${rule.trigger}” will no longer trigger this answer.',
            ru: 'Сообщения с «${rule.trigger}» больше не будут вызывать этот ответ.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(L.t('Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(L.t('Delete', ru: 'Удалить')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final bot =
          await Api.deleteBotReply(token, widget.bot.user.id, rule.id);
      _apply(bot);
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          L.t('Replies for @${widget.bot.user.username}',
              ru: 'Ответы @${widget.bot.user.username}'),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _add,
        icon: const Icon(Icons.add),
        label: Text(L.t('Add reply', ru: 'Добавить ответ')),
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                if (widget.bot.isExternal)
                  Card(
                    color: theme.colorScheme.secondaryContainer,
                    child: ListTile(
                      leading: Icon(
                        Icons.code,
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                      title: Text(
                        L.t(
                          'This bot uses an external program',
                          ru: 'Этот бот использует внешнюю программу',
                        ),
                        style: TextStyle(
                          color: theme.colorScheme.onSecondaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        L.t(
                          'Keyword replies below are stored but only run in built-in mode. Program the behaviour through the bot API instead.',
                          ru: 'Ответы ниже сохраняются, но работают только во встроенном режиме. Задайте поведение через Bot API.',
                        ),
                        style: TextStyle(
                          color: theme.colorScheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                  ),
                if (widget.bot.isExternal) const SizedBox(height: 8),
                Text(
                  L.t(
                    'When an incoming message contains a trigger, the bot replies with '
                    'the matching text. Matching is case-insensitive.',
                    ru: 'Когда входящее сообщение содержит триггер, бот отвечает '
                        'соответствующим текстом. Регистр не учитывается.',
                  ),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
                const SizedBox(height: 12),
                if (_replies.isEmpty)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.bolt_outlined),
                      title: Text(L.t('No replies yet', ru: 'Ответов пока нет')),
                      subtitle: Text(
                        L.t(
                          'Add a trigger and an answer below.',
                          ru: 'Добавьте триггер и ответ ниже.',
                        ),
                      ),
                    ),
                  )
                else
                  for (final rule in _replies)
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: const Icon(Icons.bolt_outlined),
                        title: Text('“${rule.trigger}”'),
                        subtitle: Text(
                          rule.reply,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                        ),
                        isThreeLine: rule.reply.length > 60,
                        trailing: IconButton(
                          tooltip: L.t('Delete', ru: 'Удалить'),
                          onPressed: _busy ? null : () => _delete(rule),
                          icon: Icon(
                            Icons.delete_outline,
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ),
                    ),
              ],
            ),
    );
  }
}

class _ReplyDialog extends StatefulWidget {
  const _ReplyDialog();

  @override
  State<_ReplyDialog> createState() => _ReplyDialogState();
}

class _ReplyDialogState extends State<_ReplyDialog> {
  final _trigger = TextEditingController();
  final _reply = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _trigger.dispose();
    _reply.dispose();
    super.dispose();
  }

  void _save() {
    final trigger = _trigger.text.trim();
    final reply = _reply.text.trim();
    if (trigger.isEmpty || reply.isEmpty) {
      setState(() => _error = L.t(
            'Both the trigger and the reply are required.',
            ru: 'Триггер и ответ обязательны.',
          ));
      return;
    }
    Navigator.of(context).pop(
      BotReply(id: '', trigger: trigger, reply: reply),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(L.t('New reply', ru: 'Новый ответ')),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _trigger,
                maxLength: 80,
                decoration: InputDecoration(
                  labelText: L.t('Trigger keyword', ru: 'Ключевое слово'),
                  hintText: 'ping',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 4),
              TextField(
                controller: _reply,
                minLines: 3,
                maxLines: 6,
                maxLength: 2000,
                decoration: InputDecoration(
                  labelText: L.t('Reply', ru: 'Ответ'),
                  hintText: 'pong',
                  alignLabelWithHint: true,
                  border: const OutlineInputBorder(),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(L.t('Cancel', ru: 'Отмена')),
        ),
        FilledButton(
          onPressed: _save,
          child: Text(L.t('Save', ru: 'Сохранить')),
        ),
      ],
    );
  }
}
