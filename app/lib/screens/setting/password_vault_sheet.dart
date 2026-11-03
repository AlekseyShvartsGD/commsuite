import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/localizations.dart';
import '../../services/password_vault.dart';

/// Local encrypted password vault, opened from Settings → Security.
///
/// Nothing on this screen ever reaches the server: records are encrypted with
/// AES-GCM on the device and unlocked with a dedicated vault passphrase.
class PasswordVaultSheet extends StatefulWidget {
  const PasswordVaultSheet({super.key});

  @override
  State<PasswordVaultSheet> createState() => _PasswordVaultSheetState();
}

class _PasswordVaultSheetState extends State<PasswordVaultSheet> {
  final PasswordVault _vault = PasswordVault.instance;
  final TextEditingController _passphrase = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  final Set<String> _revealed = {};

  bool _loading = true;
  bool _busy = false;
  bool _hasVault = false;
  String? _error;
  List<VaultEntry> _entries = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _vault.lock();
    _passphrase.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final has = await _vault.hasVault();
    if (!mounted) return;
    setState(() {
      _hasVault = has;
      _loading = false;
    });
  }

  Future<void> _create() async {
    final pass = _passphrase.text;
    if (pass.length < PasswordVault.minPassphraseLength) {
      setState(() => _error = L.t(
            'Use at least ${PasswordVault.minPassphraseLength} characters.',
            ru: 'Используйте не менее ${PasswordVault.minPassphraseLength} символов.',
          ));
      return;
    }
    if (pass != _confirm.text) {
      setState(() => _error = L.t(
            'The passphrases do not match.',
            ru: 'Кодовые фразы не совпадают.',
          ));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _vault.create(pass);
      _passphrase.clear();
      _confirm.clear();
      await _refreshEntries();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _hasVault = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = L.t(
          'Could not create the vault. Please try again.',
          ru: 'Не удалось создать хранилище. Попробуйте ещё раз.',
        );
      });
    }
  }

  Future<void> _unlock() async {
    if (_passphrase.text.isEmpty) {
      setState(() => _error = L.t(
            'Enter your vault passphrase.',
            ru: 'Введите кодовую фразу хранилища.',
          ));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await _vault.unlock(_passphrase.text);
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _busy = false;
        _error = L.t(
          'Wrong passphrase.',
          ru: 'Неверная кодовая фраза.',
        );
      });
      return;
    }
    _passphrase.clear();
    await _refreshEntries();
    if (!mounted) return;
    setState(() => _busy = false);
  }

  Future<void> _refreshEntries() async {
    final list = await _vault.entries();
    if (!mounted) return;
    setState(() {
      _entries = list;
      _revealed.clear();
    });
  }

  void _lock() {
    _vault.lock();
    setState(() {
      _entries = const [];
      _revealed.clear();
      _error = null;
      _passphrase.clear();
    });
  }

  Future<void> _deleteVault() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(L.t('Delete the vault?', ru: 'Удалить хранилище?')),
        content: Text(
          L.t(
            'Every saved password will be erased from this device and cannot '
            'be recovered. Your Commsuite account password is not affected.',
            ru: 'Все сохранённые пароли будут удалены с этого устройства без '
                'возможности восстановления. Пароль аккаунта Commsuite при '
                'этом не изменится.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(L.t('Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(L.t('Delete', ru: 'Удалить')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _vault.clear();
    if (!mounted) return;
    setState(() {
      _hasVault = false;
      _entries = const [];
      _revealed.clear();
      _passphrase.clear();
      _confirm.clear();
      _error = null;
    });
  }

  Future<void> _copy(VaultEntry entry) async {
    await Clipboard.setData(ClipboardData(text: entry.password));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(L.t('Password copied', ru: 'Пароль скопирован'))),
    );
  }

  Future<void> _edit([VaultEntry? entry]) async {
    final draft = await showDialog<_VaultDraft>(
      context: context,
      builder: (dialogContext) => _VaultEntryDialog(entry: entry),
    );
    if (draft == null) return;
    try {
      await _vault.save(
        id: entry?.id,
        title: draft.title,
        username: draft.username,
        password: draft.password,
        note: draft.note,
      );
      await _refreshEntries();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L.t(
            'Could not save the password.',
            ru: 'Не удалось сохранить пароль.',
          )),
        ),
      );
    }
  }

  Future<void> _remove(VaultEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(L.t('Delete this password?', ru: 'Удалить этот пароль?')),
        content: Text(entry.title),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(L.t('Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(L.t('Delete', ru: 'Удалить')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _vault.remove(entry.id);
    await _refreshEntries();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.85,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      L.t('Password vault', ru: 'Хранилище паролей'),
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: L.t('Close', ru: 'Закрыть'),
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + insets),
                      children: _hasVault
                          ? (_vault.unlocked
                              ? _unlockedView(theme)
                              : _lockedView(theme))
                          : _setupView(theme),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _setupView(ThemeData theme) {
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.password),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      L.t('Keep passwords on this device only',
                          ru: 'Храните пароли только на этом устройстве'),
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                L.t(
                  'Saved passwords are encrypted with AES-GCM before they are '
                  'written to disk. They are never sent to the server, and '
                  'support cannot recover them.',
                  ru: 'Сохранённые пароли шифруются алгоритмом AES-GCM перед '
                      'записью на диск. Они никогда не отправляются на сервер, '
                      'и поддержка не сможет их восстановить.',
                ),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _passphrase,
        obscureText: true,
        autofocus: true,
        decoration: InputDecoration(
          labelText: L.t('Vault passphrase', ru: 'Кодовая фраза хранилища'),
          helperText: L.t(
            'At least ${PasswordVault.minPassphraseLength} characters',
            ru: 'Не менее ${PasswordVault.minPassphraseLength} символов',
          ),
          border: const OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _confirm,
        obscureText: true,
        decoration: InputDecoration(
          labelText: L.t('Repeat passphrase', ru: 'Повторите кодовую фразу'),
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (_) => _create(),
      ),
      if (_error != null) ...[
        const SizedBox(height: 8),
        Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
      ],
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: _busy ? null : _create,
        icon: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.lock_outline),
        label: Text(L.t('Create vault', ru: 'Создать хранилище')),
      ),
    ];
  }

  List<Widget> _lockedView(ThemeData theme) {
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.lock_outline),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      L.t('Vault is locked', ru: 'Хранилище заблокировано'),
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                L.t(
                  'Enter the vault passphrase to view saved passwords. It is '
                  'separate from your account password and the Enigma app '
                  'passcode.',
                  ru: 'Введите кодовую фразу хранилища, чтобы увидеть сохранённые '
                      'пароли. Она не совпадает с паролем аккаунта и кодовой '
                      'фразой Enigma.',
                ),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _passphrase,
        obscureText: true,
        autofocus: true,
        decoration: InputDecoration(
          labelText: L.t('Vault passphrase', ru: 'Кодовая фраза хранилища'),
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (_) => _unlock(),
      ),
      if (_error != null) ...[
        const SizedBox(height: 8),
        Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
      ],
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: _busy ? null : _unlock,
        icon: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.lock_open),
        label: Text(L.t('Unlock', ru: 'Разблокировать')),
      ),
      const SizedBox(height: 16),
      TextButton(
        onPressed: _deleteVault,
        child: Text(
          L.t('Forgot the passphrase? Delete the vault',
              ru: 'Забыли кодовую фразу? Удалить хранилище'),
        ),
      ),
    ];
  }

  List<Widget> _unlockedView(ThemeData theme) {
    return [
      Row(
        children: [
          Expanded(
            child: Text(
              _entries.isEmpty
                  ? L.t('No saved passwords yet', ru: 'Паролей пока нет')
                  : L.t(
                      'Saved passwords: ${_entries.length}',
                      ru: 'Сохранённых паролей: ${_entries.length}',
                    ),
              style: theme.textTheme.titleSmall,
            ),
          ),
          TextButton.icon(
            onPressed: _lock,
            icon: const Icon(Icons.lock_outline, size: 18),
            label: Text(L.t('Lock', ru: 'Заблокировать')),
          ),
        ],
      ),
      const SizedBox(height: 8),
      if (_entries.isEmpty)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              L.t(
                'Add a password to keep it encrypted on this device. You can '
                'copy it or reveal it whenever you need it.',
                ru: 'Добавьте пароль, чтобы хранить его в зашифрованном виде на '
                    'этом устройстве. Его можно скопировать или показать в любой '
                    'момент.',
              ),
              style: theme.textTheme.bodySmall,
            ),
          ),
        ),
      for (final entry in _entries) ...[
        const SizedBox(height: 8),
        Card(
          child: ListTile(
            leading: const Icon(Icons.key_outlined),
            title: Text(entry.title),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (entry.username.isNotEmpty) Text(entry.username),
                Text(
                  _revealed.contains(entry.id) ? entry.password : '••••••••',
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                if (entry.note.isNotEmpty)
                  Text(
                    entry.note,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: _revealed.contains(entry.id)
                      ? L.t('Hide', ru: 'Скрыть')
                      : L.t('Reveal', ru: 'Показать'),
                  icon: Icon(
                    _revealed.contains(entry.id)
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                  onPressed: () => setState(() {
                    if (!_revealed.remove(entry.id)) {
                      _revealed.add(entry.id);
                    }
                  }),
                ),
                IconButton(
                  tooltip: L.t('Copy password', ru: 'Скопировать пароль'),
                  icon: const Icon(Icons.copy_outlined),
                  onPressed: () => _copy(entry),
                ),
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'edit') {
                      _edit(entry);
                    } else if (value == 'delete') {
                      _remove(entry);
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'edit',
                      child: Text(L.t('Edit', ru: 'Изменить')),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(L.t('Delete', ru: 'Удалить')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: Text(L.t('Add password', ru: 'Добавить пароль')),
      ),
      const SizedBox(height: 16),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          foregroundColor: theme.colorScheme.error,
        ),
        onPressed: _deleteVault,
        icon: const Icon(Icons.delete_outline),
        label: Text(L.t('Delete vault', ru: 'Удалить хранилище')),
      ),
    ];
  }
}

class _VaultDraft {
  const _VaultDraft({
    required this.title,
    required this.username,
    required this.password,
    required this.note,
  });

  final String title;
  final String username;
  final String password;
  final String note;
}

class _VaultEntryDialog extends StatefulWidget {
  const _VaultEntryDialog({this.entry});

  final VaultEntry? entry;

  @override
  State<_VaultEntryDialog> createState() => _VaultEntryDialogState();
}

class _VaultEntryDialogState extends State<_VaultEntryDialog> {
  late final TextEditingController _title =
      TextEditingController(text: widget.entry?.title ?? '');
  late final TextEditingController _username =
      TextEditingController(text: widget.entry?.username ?? '');
  late final TextEditingController _password =
      TextEditingController(text: widget.entry?.password ?? '');
  late final TextEditingController _note =
      TextEditingController(text: widget.entry?.note ?? '');
  bool _showPassword = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _username.dispose();
    _password.dispose();
    _note.dispose();
    super.dispose();
  }

  void _submit() {
    final password = _password.text;
    if (password.isEmpty) {
      setState(() => _error = L.t(
            'Enter the password to save.',
            ru: 'Введите пароль для сохранения.',
          ));
      return;
    }
    Navigator.of(context).pop(
      _VaultDraft(
        title: _title.text.trim(),
        username: _username.text.trim(),
        password: password,
        note: _note.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.entry != null;
    return AlertDialog(
      title: Text(
        editing
            ? L.t('Edit password', ru: 'Изменить пароль')
            : L.t('Add password', ru: 'Добавить пароль'),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _title,
              autofocus: true,
              decoration: InputDecoration(
                labelText: L.t('Name', ru: 'Название'),
                hintText: L.t('e.g. Commsuite account', ru: 'например, аккаунт Commsuite'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _username,
              decoration: InputDecoration(
                labelText: L.t('Username (optional)', ru: 'Имя пользователя (необязательно)'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: !_showPassword,
              decoration: InputDecoration(
                labelText: L.t('Password', ru: 'Пароль'),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: _showPassword
                      ? L.t('Hide', ru: 'Скрыть')
                      : L.t('Reveal', ru: 'Показать'),
                  icon: Icon(
                    _showPassword
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                  onPressed: () =>
                      setState(() => _showPassword = !_showPassword),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: L.t('Note (optional)', ru: 'Заметка (необязательно)'),
                border: const OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(L.t('Cancel', ru: 'Отмена')),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(L.t('Save', ru: 'Сохранить')),
        ),
      ],
    );
  }
}
