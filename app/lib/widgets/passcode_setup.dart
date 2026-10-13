import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/localizations.dart';
import '../services/lock_service.dart';

Future<bool> showPasscodeSetupDialog(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => const _PasscodeSetupDialog(),
  );
  return result ?? false;
}

class _PasscodeSetupDialog extends StatefulWidget {
  const _PasscodeSetupDialog();

  @override
  State<_PasscodeSetupDialog> createState() => _PasscodeSetupDialogState();
}

class _PasscodeSetupDialogState extends State<_PasscodeSetupDialog> {
  final _passcode = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _passcode.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final value = _passcode.text.trim();
    if (value.length < 4) {
      setState(() => _error =
          L.t('Use at least 4 letters', ru: 'Минимум 4 буквы'));
      return;
    }
    if (value != _confirm.text.trim()) {
      setState(() => _error =
          L.t('Passcodes do not match', ru: 'Кодовые фразы не совпадают'));
      return;
    }
    await LockService.instance.setPasscode(value);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.key_outlined),
      title: Text(L.t('Enigma passcode', ru: 'Кодовая фраза Enigma')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            L.t(
              'Letters A-Z only. This passcode locks the app and any chats you choose.',
              ru: 'Только буквы A-Z. Этот код блокирует приложение и выбранные чаты.',
            ),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _passcode,
            autofocus: true,
            obscureText: true,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp('[A-Za-z]')),
            ],
            decoration: InputDecoration(
              labelText: L.t('New passcode', ru: 'Новая кодовая фраза'),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _confirm,
            obscureText: true,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp('[A-Za-z]')),
            ],
            onSubmitted: (_) => _save(),
            decoration: InputDecoration(
              labelText: L.t('Confirm passcode', ru: 'Повторите кодовую фразу'),
              errorText: _error,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
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
