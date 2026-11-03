import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app.dart';
import '../../core/api.dart';
import '../../core/localizations.dart';

/// Enable, inspect and disable TOTP two-factor authentication. The sheet is
/// opened from Settings → Security and talks to the server through
/// [CommsController]; recovery codes are shown exactly once.
class TwoFactorSheet extends StatefulWidget {
  const TwoFactorSheet({super.key});

  @override
  State<TwoFactorSheet> createState() => _TwoFactorSheetState();
}

class _TwoFactorSheetState extends State<TwoFactorSheet> {
  final TextEditingController _codeController = TextEditingController();
  bool _loading = true;
  bool _busy = false;
  bool _enabled = false;
  int _remaining = 0;
  TwoFactorSetup? _setup;
  List<String>? _recoveryCodes;
  bool _savedCodes = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final status = await CommsScope.read(context).loadTwoFactorStatus();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _enabled = status?.enabled ?? false;
      _remaining = status?.remainingRecoveryCodes ?? 0;
    });
  }

  Future<void> _startSetup() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final setup = await CommsScope.read(context).beginTwoFactorSetup();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _setup = setup;
      if (setup == null) {
        _error = L.t(
          'Could not start setup. Please try again.',
          ru: 'Не удалось начать настройку. Попробуйте ещё раз.',
        );
      }
    });
  }

  Future<void> _enable() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      setState(() {
        _error = L.t(
          'Enter the code from your authenticator app.',
          ru: 'Введите код из приложения-аутентификатора.',
        );
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final codes = await CommsScope.read(context).confirmTwoFactorSetup(code);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (codes != null) {
        _recoveryCodes = codes;
        _enabled = true;
        _remaining = codes.length;
        _setup = null;
        _codeController.clear();
      } else {
        _error = L.t(
          'That code did not work. Check your device clock and try again.',
          ru:
              'Код не подошёл. Проверьте время на устройстве и попробуйте снова.',
        );
      }
    });
  }

  Future<void> _copyRecoveryCodes() async {
    final codes = _recoveryCodes;
    if (codes == null) return;
    await Clipboard.setData(ClipboardData(text: codes.join('\n')));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          L.t('Recovery codes copied', ru: 'Коды восстановления скопированы'),
        ),
      ),
    );
  }

  Future<void> _disable() async {
    final controller = CommsScope.read(context);
    final passwordController = TextEditingController();
    final codeController = TextEditingController();
    String? error;
    bool busy = false;

    final disabled = await showDialog<bool>(
      context: context,
      barrierDismissible: !busy,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          Future<void> submit() async {
            if (busy) return;
            setDialogState(() {
              busy = true;
              error = null;
            });
            final err = await controller.disableTwoFactor(
              passwordController.text,
              codeController.text,
            );
            if (!dialogContext.mounted) return;
            if (err == null) {
              Navigator.of(dialogContext).pop(true);
            } else {
              setDialogState(() {
                busy = false;
                error = err;
              });
            }
          }

          return AlertDialog(
            title: Text(
              L.t(
                'Turn off two-factor authentication?',
                ru: 'Отключить двухфакторную аутентификацию?',
              ),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  L.t(
                    'Confirm your password and a current authenticator code '
                    '(or a recovery code).',
                    ru:
                        'Подтвердите пароль и текущий код аутентификатора '
                        '(или код восстановления).',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: L.t('Password', ru: 'Пароль'),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: codeController,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    labelText: L.t('Code', ru: 'Код'),
                    hintText: '123456 / XXXX-XXXX',
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => submit(),
                ),
                if (error != null) ...[
                  const SizedBox(height: 12),
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
                    : Text(L.t('Turn off', ru: 'Отключить')),
              ),
            ],
          );
        },
      ),
    );

    passwordController.dispose();
    codeController.dispose();
    if (disabled == true && mounted) {
      setState(() {
        _enabled = false;
        _remaining = 0;
        _recoveryCodes = null;
        _setup = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.t(
              'Two-factor authentication disabled',
              ru: 'Двухфакторная аутентификация отключена',
            ),
          ),
        ),
      );
    }
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
                      L.t(
                        'Two-factor authentication',
                        ru: 'Двухфакторная аутентификация',
                      ),
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
                      children: _recoveryCodes != null
                          ? _recoveryCodeView(theme)
                          : _enabled
                              ? _enabledView(theme)
                              : _disabledView(theme),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _disabledView(ThemeData theme) {
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.shield_outlined),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      L.t(
                        'Protect your account with an authenticator app',
                        ru: 'Защитите аккаунт приложением-аутентификатором',
                      ),
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                L.t(
                  'After your password, Commsuite asks for a 6-digit code from '
                  'an app such as Google Authenticator, Microsoft '
                  'Authenticator, Aegis or 1Password. You also get ten '
                  'single-use recovery codes.',
                  ru:
                      'После пароля Commsuite попросит 6-значный код из '
                      'приложения вроде Google Authenticator, Microsoft '
                      'Authenticator, Aegis или 1Password. Вы также получите '
                      'десять одноразовых кодов восстановления.',
                ),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      if (_setup == null)
        FilledButton.icon(
          onPressed: _busy ? null : _startSetup,
          icon: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.qr_code_2),
          label: Text(L.t('Set up', ru: 'Настроить')),
        )
      else ...[
        Text(
          L.t('1. Scan this QR code', ru: '1. Отсканируйте QR-код'),
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 12),
        Center(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: QrImageView(
              data: _setup!.otpauthUrl,
              version: QrVersions.auto,
              size: 220,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          L.t(
            'Can\u2019t scan? Enter this key manually:',
            ru: 'Не получается отсканировать? Введите ключ вручную:',
          ),
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: SelectableText(
                _setup!.secret,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 15,
                  letterSpacing: 1.5,
                ),
              ),
            ),
            IconButton(
              tooltip: L.t('Copy key', ru: 'Скопировать ключ'),
              icon: const Icon(Icons.copy),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _setup!.secret));
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      L.t('Setup key copied', ru: 'Ключ настройки скопирован'),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 20),
        Text(
          L.t(
            '2. Enter the 6-digit code from the app',
            ru: '2. Введите 6-значный код из приложения',
          ),
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _codeController,
          keyboardType: TextInputType.number,
          maxLength: 6,
          decoration: InputDecoration(
            labelText: L.t('Code', ru: 'Код'),
            hintText: '123456',
            border: const OutlineInputBorder(),
            counterText: '',
          ),
          onSubmitted: (_) => _enable(),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ],
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy ? null : _enable,
          icon: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.check),
          label: Text(L.t('Enable', ru: 'Включить')),
        ),
      ],
    ];
  }

  List<Widget> _enabledView(ThemeData theme) {
    return [
      Card(
        child: ListTile(
          leading: const Icon(Icons.verified_user_outlined, color: Colors.green),
          title: Text(
            L.t('Two-factor authentication is on', ru: 'Защита включена'),
          ),
          subtitle: Text(
            L.t(
              'Your password plus an authenticator code are required to sign in.',
              ru:
                  'Для входа нужны пароль и код из приложения-аутентификатора.',
            ),
          ),
        ),
      ),
      const SizedBox(height: 8),
      Card(
        child: ListTile(
          leading: const Icon(Icons.key_outlined),
          title: Text(
            L.t('Recovery codes', ru: 'Коды восстановления'),
          ),
          subtitle: Text(
            _remaining == 1
                ? L.t('1 unused code left', ru: 'Остался 1 неиспользованный код')
                : L.t(
                    '$_remaining unused codes left',
                    ru: 'Осталось неиспользованных кодов: $_remaining',
                  ),
          ),
        ),
      ),
      const SizedBox(height: 8),
      if (_remaining == 0)
        Card(
          color: theme.colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              L.t(
                'You have used all recovery codes. Turn two-factor '
                'authentication off and on again to generate a new set.',
                ru:
                    'Вы использовали все коды восстановления. Отключите и снова '
                    'включите двухфакторную аутентификацию, чтобы получить новый '
                    'набор.',
              ),
              style: TextStyle(color: theme.colorScheme.onErrorContainer),
            ),
          ),
        ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
        onPressed: _busy ? null : _disable,
        icon: const Icon(Icons.lock_open),
        label: Text(
          L.t('Turn off two-factor authentication', ru: 'Отключить защиту'),
        ),
      ),
    ];
  }

  List<Widget> _recoveryCodeView(ThemeData theme) {
    final codes = _recoveryCodes ?? const <String>[];
    return [
      Card(
        color: theme.colorScheme.tertiaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.warning_amber_rounded),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      L.t(
                        'Save these recovery codes now',
                        ru: 'Сохраните коды восстановления сейчас',
                      ),
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                L.t(
                  'Each code works once if you lose access to your '
                  'authenticator app. They will not be shown again.',
                  ru:
                      'Каждый код сработает один раз, если вы потеряете доступ к '
                      'приложению-аутентификатору. Больше они не будут показаны.',
                ),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: SelectableText(
          codes.join('\n'),
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 16,
            height: 1.6,
            letterSpacing: 1,
          ),
        ),
      ),
      const SizedBox(height: 12),
      FilledButton.tonalIcon(
        onPressed: _copyRecoveryCodes,
        icon: const Icon(Icons.copy_all_outlined),
        label: Text(L.t('Copy all codes', ru: 'Скопировать все коды')),
      ),
      const SizedBox(height: 8),
      CheckboxListTile(
        value: _savedCodes,
        onChanged: (value) => setState(() => _savedCodes = value ?? false),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(
          L.t(
            'I saved these codes in a safe place',
            ru: 'Я сохранил(а) коды в надёжном месте',
          ),
        ),
      ),
      FilledButton(
        onPressed: _savedCodes ? () => Navigator.of(context).pop() : null,
        child: Text(L.t('Done', ru: 'Готово')),
      ),
    ];
  }
}
