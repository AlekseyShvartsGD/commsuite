import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/localizations.dart';
import '../../services/password_vault.dart';

/// Change the account password. The server verifies the current password and
/// stores only a bcrypt hash of the new one, so nobody (including support) can
/// recover it later.
class ChangePasswordSheet extends StatefulWidget {
  const ChangePasswordSheet({super.key});

  @override
  State<ChangePasswordSheet> createState() => _ChangePasswordSheetState();
}

class _ChangePasswordSheetState extends State<ChangePasswordSheet> {
  final TextEditingController _current = TextEditingController();
  final TextEditingController _next = TextEditingController();
  final TextEditingController _confirm = TextEditingController();

  bool _busy = false;
  bool _hasVault = false;
  bool _saveToVault = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final has = await PasswordVault.instance.hasVault();
      if (mounted) setState(() => _hasVault = has);
    });
  }

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _unlockVault() async {
    final vault = PasswordVault.instance;
    final passphrase = TextEditingController();
    String? error;
    bool busy = false;
    final unlocked = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          Future<void> submit() async {
            if (busy) return;
            setDialogState(() {
              busy = true;
              error = null;
            });
            final ok = await vault.unlock(passphrase.text);
            if (!dialogContext.mounted) return;
            if (ok) {
              Navigator.of(dialogContext).pop(true);
            } else {
              setDialogState(() {
                busy = false;
                error = L.t(
                  'Wrong passphrase.',
                  ru: 'Неверная кодовая фраза.',
                );
              });
            }
          }

          return AlertDialog(
            title: Text(
              L.t('Unlock the password vault',
                  ru: 'Разблокировать хранилище паролей'),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: passphrase,
                  obscureText: true,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText:
                        L.t('Vault passphrase', ru: 'Кодовая фраза хранилища'),
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => submit(),
                ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(dialogContext).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed:
                    busy ? null : () => Navigator.of(dialogContext).pop(false),
                child: Text(L.t('Cancel', ru: 'Отмена')),
              ),
              FilledButton(
                onPressed: busy ? null : submit,
                child: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(L.t('Unlock', ru: 'Разблокировать')),
              ),
            ],
          );
        },
      ),
    );
    passphrase.dispose();
    if (unlocked == true && mounted) setState(() {});
  }

  Future<void> _submit() async {
    final current = _current.text;
    final next = _next.text;
    if (current.isEmpty) {
      setState(() => _error = L.t(
            'Enter your current password.',
            ru: 'Введите текущий пароль.',
          ));
      return;
    }
    if (next.length < 6) {
      setState(() => _error = L.t(
            'The new password must be at least 6 characters.',
            ru: 'Новый пароль должен быть не короче 6 символов.',
          ));
      return;
    }
    if (next == current) {
      setState(() => _error = L.t(
            'The new password must be different from the current one.',
            ru: 'Новый пароль должен отличаться от текущего.',
          ));
      return;
    }
    if (next != _confirm.text) {
      setState(() => _error = L.t(
            'The new passwords do not match.',
            ru: 'Новые пароли не совпадают.',
          ));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final controller = CommsScope.read(context);
    final err = await controller.changePassword(current, next);
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _error = err;
      });
      return;
    }
    if (_saveToVault && PasswordVault.instance.unlocked) {
      try {
        final vault = PasswordVault.instance;
        final username = controller.user?.username ?? '';
        final title = 'Commsuite (@$username)';
        final existing = await vault.entries();
        VaultEntry? match;
        for (final entry in existing) {
          if (entry.title == title) {
            match = entry;
            break;
          }
        }
        await vault.save(
          id: match?.id,
          title: title,
          username: username,
          password: next,
          note: L.t('Account password', ru: 'Пароль аккаунта'),
        );
      } catch (_) {
        // The password was changed on the server; failing to mirror it into
        // the local vault must not turn that success into an error.
      }
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final vault = PasswordVault.instance;
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
                      L.t('Change password', ru: 'Сменить пароль'),
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
              child: ListView(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + insets),
                children: [
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
                                  L.t(
                                    'Your password is never stored in plain text',
                                    ru: 'Пароль никогда не хранится в открытом виде',
                                  ),
                                  style: theme.textTheme.titleSmall,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            L.t(
                              'Commsuite keeps only a bcrypt hash on the '
                              'server. If you forget the password, it cannot be '
                              'recovered — you will need to use the local vault '
                              'or reset the account.',
                              ru: 'Commsuite хранит на сервере только bcrypt-хеш. '
                                  'Если вы забудете пароль, восстановить его '
                                  'нельзя — используйте локальное хранилище или '
                                  'сбросьте аккаунт.',
                            ),
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _current,
                    obscureText: true,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: L.t('Current password', ru: 'Текущий пароль'),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _next,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: L.t('New password', ru: 'Новый пароль'),
                      helperText: L.t(
                        'At least 6 characters',
                        ru: 'Не менее 6 символов',
                      ),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _confirm,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: L.t('Repeat new password', ru: 'Повторите новый пароль'),
                      border: const OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ],
                  if (_hasVault) ...[
                    const SizedBox(height: 8),
                    if (!vault.unlocked)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.lock_outline),
                          title: Text(
                            L.t('Vault is locked',
                                ru: 'Хранилище заблокировано'),
                          ),
                          subtitle: Text(
                            L.t(
                              'Unlock it to save the new password on this device.',
                              ru: 'Разблокируйте его, чтобы сохранить новый '
                                  'пароль на этом устройстве.',
                            ),
                          ),
                          trailing: TextButton(
                            onPressed: _unlockVault,
                            child: Text(L.t('Unlock', ru: 'Разблокировать')),
                          ),
                        ),
                      ),
                    if (vault.unlocked)
                      CheckboxListTile(
                        value: _saveToVault,
                        onChanged: (value) =>
                            setState(() => _saveToVault = value ?? false),
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(
                          L.t('Save the new password in the local vault',
                              ru: 'Сохранить новый пароль в локальном хранилище'),
                        ),
                      ),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _busy ? null : _submit,
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check),
                    label: Text(L.t('Change password', ru: 'Сменить пароль')),
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
