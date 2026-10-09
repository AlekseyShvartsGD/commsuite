import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/app_config.dart';
import '../../core/app_version.dart';
import '../../core/localizations.dart';
import '../../services/autostart_service.dart';
import '../../widgets/user_avatar.dart';
import '../mod/mod_reports_screen.dart';
import '../mod/mod_banned_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _serverController;
  late final TextEditingController _turnHostController;
  late final TextEditingController _turnPortController;
  late final TextEditingController _turnUserController;
  late final TextEditingController _turnPassController;
  final TextEditingController _bioController = TextEditingController();
  final TextEditingController _vtKeyController = TextEditingController();
  final TextEditingController _vtProxyController = TextEditingController();
  bool _autostartEnabled = false;
  bool _autostartLoaded = false;

  @override
  void initState() {
    super.initState();
    _serverController = TextEditingController(text: AppConfig.serverUrl);
    _turnHostController = TextEditingController(text: AppConfig.turnHost);
    _turnPortController = TextEditingController(
      text: AppConfig.turnPort > 0 ? '${AppConfig.turnPort}' : '',
    );
    _turnUserController = TextEditingController(text: AppConfig.turnUser);
    _turnPassController = TextEditingController(text: AppConfig.turnPass);
    _bioController.text = CommsScope.read(context).user?.bio ?? '';
    AppConfig.loadVirusTotalKey().then((key) {
      if (mounted) _vtKeyController.text = key ?? '';
    });
    AppConfig.loadVirusTotalProxy().then((proxy) {
      if (mounted) _vtProxyController.text = proxy;
    });
    if (AutostartService.supported) {
      AutostartService.isEnabled().then((enabled) {
        if (mounted) {
          setState(() {
            _autostartEnabled = enabled;
            _autostartLoaded = true;
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _serverController.dispose();
    _turnHostController.dispose();
    _turnPortController.dispose();
    _turnUserController.dispose();
    _turnPassController.dispose();
    _bioController.dispose();
    _vtKeyController.dispose();
    _vtProxyController.dispose();
    super.dispose();
  }

  Future<void> _saveVtKey() async {
    await AppConfig.setVirusTotalKey(_vtKeyController.text);
    await AppConfig.setVirusTotalProxy(_vtProxyController.text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(L.t('VirusTotal API key saved',
              ru: 'Ключ VirusTotal API сохранён'))),
    );
  }

  Future<void> _saveServer() async {
    final controller = CommsScope.read(context);
    await AppConfig.setServerUrl(_serverController.text);
    await controller.reconnect();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(L.t('Server updated and reconnecting…',
              ru: 'Сервер обновлён, переподключение…'))),
    );
  }

  Future<void> _saveTurn() async {
    final host = _turnHostController.text.trim();
    final port = int.tryParse(_turnPortController.text.trim()) ?? 0;
    final user = _turnUserController.text.trim();
    final pass = _turnPassController.text.trim();
    if (port <= 0 || port > 65535) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(L.t('TURN port must be between 1 and 65535',
                ru: 'Порт TURN должен быть от 1 до 65535'))),
      );
      return;
    }
    await AppConfig.setTurn(host: host, port: port, user: user, pass: pass);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppConfig.turnEnabled
            ? L.t('Call relay saved. Calls will go through $host:$port over TCP.',
                ru: 'Ретранслятор сохранён. Звонки пойдут через $host:$port по TCP.')
            : L.t('Call relay cleared. Calls fall back to direct (STUN).',
                ru: 'Ретранслятор очищен. Звонки снова идут напрямую (STUN).')),
      ),
    );
  }

  Future<void> _toggleAutostart(bool enabled) async {
    final ok = await AutostartService.setEnabled(enabled);
    if (!mounted) return;
    if (ok) {
      setState(() {
        _autostartEnabled = enabled;
      });
      return;
    }
    // Re-read the real registry state so the switch can't drift from it.
    final actual = await AutostartService.isEnabled();
    if (!mounted) return;
    setState(() {
      _autostartEnabled = actual;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(L.t('Could not update startup setting.',
              ru: 'Не удалось изменить параметр автозапуска.'))),
    );
  }

  Future<void> _saveBio() async {
    final controller = CommsScope.read(context);
    final bio = _bioController.text.trim();
    if (bio.isEmpty || bio == controller.user?.bio) return;
    await controller.updateBio(bio);
    if (mounted) setState(() {});
  }

  Future<void> _setLanguage(String code) async {
    L.setLang(code);
    await AppConfig.setLanguage(code);
    if (mounted) setState(() {});
  }

  Future<void> _logout() async {
    final controller = CommsScope.read(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(L.t('Sign out?', ru: 'Выйти?')),
        content: Text(L.t('You will be disconnected from this device.',
            ru: 'Вы будете отключены от этого устройства.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(L.t('Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(L.t('Sign out', ru: 'Выйти')),
          ),
        ],
      ),
    );
    if (ok == true) {
      await controller.logout();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = CommsScope.of(context);
    final user = controller.user;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(L.t('Settings', ru: 'Настройки'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (user != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    UserAvatar(
                      name: user.displayName,
                      seed: user.username,
                      radius: 28,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            user.displayName,
                            style: theme.textTheme.titleMedium,
                          ),
                          Text('@${user.username}', style: theme.textTheme.bodySmall),
                          const SizedBox(height: 2),
                          Text(
                            'ID: ${user.id}',
                            style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    ValueListenableBuilder(
                      valueListenable: controller.channel.connected,
                      builder: (context, connected, _) => Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            connected ? Icons.cloud_done : Icons.cloud_off,
                            size: 18,
                            color: connected ? Colors.green : Colors.grey,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            connected
                                ? L.t('Online', ru: 'В сети')
                                : L.t('Offline', ru: 'Не в сети'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 16),
          if (user != null) ...[
            Text(L.t('Your bio', ru: 'О себе'), style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            TextField(
              controller: _bioController,
              maxLines: 2,
              maxLength: 300,
              decoration: InputDecoration(
                hintText: L.t('What\u2019s on your mind?', ru: 'Что у вас на уме?'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _saveBio,
              icon: const Icon(Icons.save_outlined),
              label: Text(L.t('Save bio', ru: 'Сохранить')),
            ),
            if (user.isMod) ...[
              const SizedBox(height: 24),
              Text(L.t('Moderator', ru: 'Модератор'),
                  style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.admin_panel_settings_outlined),
                  title: Text(L.t('Moderation queue',
                      ru: 'Очередь модерации')),
                  subtitle: Text(L.t('Review and resolve user reports',
                      ru: 'Просмотр и решение жалоб пользователей')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const ModReportsScreen()),
                  ),
                ),
              ),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.person_off_outlined),
                  title:
                      Text(L.t('Banned accounts', ru: 'Заблокированные аккаунты')),
                  subtitle: Text(L.t('View and unban banned users',
                      ru: 'Просмотр и разблокировка пользователей')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ModBannedScreen()),
                  ),
                ),
              ),
            ],
          ],
          const SizedBox(height: 24),
          Text(L.t('Server', ru: 'Сервер'), style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: _serverController,
            decoration: InputDecoration(
              labelText: L.t('Server address', ru: 'Адрес сервера'),
              hintText: 'http://192.168.1.10:3000',
              prefixIcon: const Icon(Icons.dns_outlined),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _saveServer,
            icon: const Icon(Icons.save_outlined),
            label: Text(L.t('Save & reconnect', ru: 'Сохранить и переподключиться')),
          ),
          const SizedBox(height: 24),
          Text(L.t('Calls (TURN relay)', ru: 'Звонки (TURN-ретранслятор)'),
              style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: _turnHostController,
            decoration: InputDecoration(
              labelText: L.t('TURN host', ru: 'TURN-хост'),
              hintText: 'tcp.cloudpub.ru',
              prefixIcon: const Icon(Icons.router_outlined),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _turnPortController,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: L.t('TURN port', ru: 'TURN-порт'),
              hintText: '3478',
              prefixIcon: const Icon(Icons.numbers),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _turnUserController,
            decoration: InputDecoration(
              labelText: L.t('TURN username', ru: 'TURN-имя пользователя'),
              hintText: 'commsuite',
              prefixIcon: const Icon(Icons.person_outline),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _turnPassController,
            obscureText: true,
            decoration: InputDecoration(
              labelText: L.t('TURN password', ru: 'TURN-пароль'),
              hintText: 'commsuite-1',
              prefixIcon: const Icon(Icons.key_outlined),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: _saveTurn,
            icon: const Icon(Icons.save_outlined),
            label: Text(L.t('Save call relay', ru: 'Сохранить ретранслятор')),
          ),
          const SizedBox(height: 4),
          Text(
            L.t(
              'For TCP-only networks: leave empty to use direct STUN, or enter a '
              'TURN relay. Calls then flow exclusively through the relay over TCP.',
              ru: 'Для сетей только с TCP: оставьте пустым, чтобы использовать '
                  'прямой STUN, или укажите TURN-ретранслятор. Тогда звонки '
                  'будут идти исключительно через ретранслятор по TCP.',
            ),
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 24),
          Text(L.t('Security (VirusTotal)', ru: 'Безопасность (VirusTotal)'),
              style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: _vtKeyController,
            obscureText: true,
            decoration: InputDecoration(
              labelText:
                  L.t('VirusTotal API key', ru: 'Ключ API VirusTotal'),
              hintText: L.t('Paste your free VirusTotal API key',
                  ru: 'Вставьте ваш бесплатный ключ API VirusTotal'),
              prefixIcon: const Icon(Icons.shield_outlined),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _vtProxyController,
            decoration: InputDecoration(
              labelText: L.t('Proxy (optional)', ru: 'Прокси (необязательно)'),
              hintText: '127.0.0.1:7890 or socks5://127.0.0.1:1080',
              prefixIcon: const Icon(Icons.vpn_lock_outlined),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            L.t(
              'VirusTotal is blocked on some networks. Route its requests through '
              'a local VPN/proxy: an HTTP proxy as host:port, or SOCKS5 as '
              'socks5://host:port. Leave empty to connect directly.',
              ru: 'VirusTotal заблокирован в некоторых сетях. Направьте его '
                  'запросы через локальный VPN/прокси: HTTP-прокси как host:port '
                  'или SOCKS5 как socks5://host:port. Оставьте пустым, чтобы '
                  'подключаться напрямую.',
            ),
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: _saveVtKey,
            icon: const Icon(Icons.save_outlined),
            label: Text(L.t('Save key', ru: 'Сохранить ключ')),
          ),
          const SizedBox(height: 24),
          Text(L.t('App', ru: 'Приложение'), style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Commsuite'),
              subtitle: Text(L.t(
                'Version $appVersion\n'
                    'Chat, voice/video calls, browser and file manager.\n'
                    'Self-hosted: run server/ and point this app at it.',
                ru: 'Версия $appVersion\n'
                    'Чаты, голосовые и видеозвонки, браузер и файловый менеджер.\n'
                    'Свой сервер: запустите server/ и укажите его в этом приложении.',
              )),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.translate),
              title: Text(L.t('Language', ru: 'Язык')),
            ),
          ),
          Card(
            child: RadioGroup<String>(
              groupValue: L.lang,
              onChanged: (v) => _setLanguage(v ?? L.lang),
              child: const Column(
                children: [
                  RadioListTile<String>(
                    value: 'en',
                    title: Text('English'),
                  ),
                  RadioListTile<String>(
                    value: 'ru',
                    title: Text('Русский'),
                  ),
                ],
              ),
            ),
          ),
          if (AutostartService.supported) ...[
            const SizedBox(height: 8),
            Card(
              child: SwitchListTile(
                secondary: const Icon(Icons.power_settings_new),
                title: Text(L.t('Start with Windows',
                    ru: 'Запускать вместе с Windows')),
                subtitle: Text(L.t(
                    'Launch hidden in the system tray when you sign in',
                    ru: 'Запускать скрыто в системном трее при входе в систему')),
                value: _autostartLoaded && _autostartEnabled,
                onChanged: _autostartLoaded ? _toggleAutostart : null,
              ),
            ),
          ],
          const SizedBox(height: 32),
          OutlinedButton.icon(
            onPressed: _logout,
            icon: const Icon(Icons.logout),
            label: Text(L.t('Sign out', ru: 'Выйти')),
            style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
          ),
        ],
      ),
    );
  }
}