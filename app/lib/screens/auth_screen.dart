import 'dart:math';

import 'package:flutter/material.dart';

import '../app.dart';
import '../core/app_config.dart';
import '../core/localizations.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

const _starterBios = [
  'Just joined Commsuite - say hi!',
  'New here, exploring Commsuite.',
  'Talk to me, I do not bite.',
  'Building something on Commsuite.',
  'Here for good chats and calls.',
];

class _AuthScreenState extends State<AuthScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _serverController = TextEditingController();
  final _nameController = TextEditingController();
  final _bioController = TextEditingController();
  final _userController = TextEditingController();
  final _passController = TextEditingController();
  final _registerUserController = TextEditingController();
  final _registerPassController = TextEditingController();
  bool _busy = false;
  String? _error;
  bool _rememberMe = AppConfig.rememberMe;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this, initialIndex: 0);
    _serverController.text = AppConfig.serverUrl;
    _bioController.text = _starterBios[Random().nextInt(_starterBios.length)];
  }

  @override
  void dispose() {
    _tabs.dispose();
    _serverController.dispose();
    _nameController.dispose();
    _bioController.dispose();
    _userController.dispose();
    _passController.dispose();
    _registerUserController.dispose();
    _registerPassController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final controller = CommsScope.read(context);
    String? err;
    if (_tabs.index == 0) {
      err = await controller.login(
        _userController.text.trim(),
        _passController.text,
      );
    } else {
      err = await controller.register(
        _registerUserController.text.trim(),
        _registerPassController.text,
        _nameController.text.trim(),
        bio: _bioController.text.trim(),
      );
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
  }

  Future<void> _saveServer() async {
    await AppConfig.setServerUrl(_serverController.text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(L.t('Server URL saved', ru: 'Адрес сервера сохранён')),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Image.asset(
                    'assets/icons/app_icon.png',
                    width: 72,
                    height: 72,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Commsuite',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    L.t(
                      'chat, call, browse and manage files — together',
                      ru: 'чат, звонки, браузер и файлы — вместе',
                    ),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _serverController,
                    decoration: InputDecoration(
                      labelText: L.t('Server address', ru: 'Адрес сервера'),
                      hintText: 'http://192.168.1.10:3000',
                      prefixIcon: const Icon(Icons.dns_outlined),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _saveServer,
                      child: Text(L.t('Save server', ru: 'Сохранить сервер')),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Material(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(28),
                    child: TabBar(
                      controller: _tabs,
                      tabs: const [
                        Tab(text: 'Sign in'),
                        Tab(text: 'Create account'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  AnimatedBuilder(
                    animation: _tabs,
                    builder: (context, _) {
                      final isLogin = _tabs.index == 0;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (!isLogin) ...[
                            TextField(
                              controller: _nameController,
                              decoration: InputDecoration(
                                labelText: L.t(
                                  'Display name',
                                  ru: 'Отображаемое имя',
                                ),
                                border: const OutlineInputBorder(),
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _bioController,
                              decoration: InputDecoration(
                                labelText: L.t('Bio (about)', ru: 'О себе'),
                                helperText: L.t(
                                  'You can edit it anytime from Settings',
                                  ru: 'Вы сможете изменить её позже в настройках',
                                ),
                                border: const OutlineInputBorder(),
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],
                          TextField(
                            controller: isLogin
                                ? _userController
                                : _registerUserController,
                            decoration: InputDecoration(
                              labelText: L.t(
                                'Username',
                                ru: 'Имя пользователя',
                              ),
                              hintText: L.t(
                                '3-32 chars: a-z 0-9 _ . -',
                                ru: '3-32 символа: a-z 0-9 _ . -',
                              ),
                              border: const OutlineInputBorder(),
                            ),
                            onSubmitted: (_) => _submit(),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: isLogin
                                ? _passController
                                : _registerPassController,
                            obscureText: true,
                            decoration: InputDecoration(
                              labelText: L.t('Password', ru: 'Пароль'),
                              hintText: L.t(
                                'at least 6 characters',
                                ru: 'не менее 6 символов',
                              ),
                              border: const OutlineInputBorder(),
                            ),
                            onSubmitted: (_) => _submit(),
                          ),
                          if (_error != null) ...[
                            const SizedBox(height: 12),
                            Text(
                              _error!,
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                          ],
                          const SizedBox(height: 4),
                          CheckboxListTile(
                            value: _rememberMe,
                            onChanged: (v) {
                              setState(() => _rememberMe = v ?? true);
                              AppConfig.setRememberMe(v ?? true);
                            },
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            title: Text(
                              L.t('Remember me', ru: 'Запомнить меня'),
                              style: const TextStyle(fontSize: 14),
                            ),
                            subtitle: Text(
                              _rememberMe
                                  ? L.t(
                                      'Stay signed in on this device',
                                      ru: 'Оставаться в системе на этом устройстве',
                                    )
                                  : L.t(
                                      'Sign out automatically when the app closes',
                                      ru: 'Выходить автоматически при закрытии приложения',
                                    ),
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: _busy ? null : _submit,
                            child: _busy
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Text(
                                    isLogin
                                        ? L.t('Sign in', ru: 'Войти')
                                        : L.t(
                                            'Create account',
                                            ru: 'Создать аккаунт',
                                          ),
                                  ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  Text(
                    L.t(
                      'Tip: use 10.0.2.2 from the Android emulator; use your PC LAN IP '
                      'on a real device.',
                      ru:
                          'Подсказка: используйте 10.0.2.2 из Android-эмулятора; '
                          'на реальном устройстве используйте локальный IP вашего ПК.',
                    ),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
