import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/localizations.dart';

class PasscodeLock extends StatefulWidget {
  const PasscodeLock({
    super.key,
    required this.title,
    this.subtitle,
    this.icon = Icons.lock_outline,
    required this.verify,
    this.biometric,
    required this.onUnlocked,
    this.onCancel,
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final Future<bool> Function(String passcode) verify;
  final Future<bool> Function()? biometric;
  final VoidCallback onUnlocked;
  final VoidCallback? onCancel;

  @override
  State<PasscodeLock> createState() => _PasscodeLockState();
}

class _PasscodeLockState extends State<PasscodeLock> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusNode.requestFocus());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await widget.verify(value);
    if (!mounted) return;
    if (ok) {
      setState(() => _busy = false);
      widget.onUnlocked();
      return;
    }
    setState(() {
      _busy = false;
      _error = L.t('Incorrect passcode', ru: 'Неверный код');
      _controller.clear();
    });
    // Ensure focus stays in the input so typing feels normal.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  Future<void> _biometric() async {
    final run = widget.biometric;
    if (run == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await run();
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) widget.onUnlocked();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: widget.onCancel == null
          ? null
          : AppBar(
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: widget.onCancel,
              ),
            ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(widget.icon, size: 56, color: scheme.primary),
                  const SizedBox(height: 16),
                  Text(
                    widget.title,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  if (widget.subtitle != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      widget.subtitle!,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    autofocus: true,
                    obscureText: true,
                    enabled: !_busy,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp('[A-Za-z]')),
                    ],
                    decoration: InputDecoration(
                      labelText: L.t('Enigma passcode', ru: 'Кодовая фраза'),
                      helperText: L.t('Letters A-Z only', ru: 'Только буквы A-Z'),
                      errorText: _error,
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.key_outlined),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(L.t('Unlock', ru: 'Разблокировать')),
                    ),
                  ),
                  if (widget.biometric != null) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _biometric,
                        icon: const Icon(Icons.fingerprint),
                        label: Text(
                          L.t('Use fingerprint', ru: 'Отпечаток пальца'),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
