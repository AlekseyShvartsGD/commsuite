import 'package:flutter/material.dart';

import '../app.dart';
import '../core/localizations.dart';
import '../services/url_service.dart';
import 'browser/browser_screen.dart';
import 'chat/conversations_screen.dart';
import 'contacts/contacts_screen.dart';
import 'files/files_screen.dart';
import 'setting/settings_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    BrowserRequest.request.addListener(_onBrowserRequest);
  }

  @override
  void dispose() {
    BrowserRequest.request.removeListener(_onBrowserRequest);
    super.dispose();
  }

  /// Redirect the user to the Browse tab when a chat link requests the
  /// built-in browser.
  void _onBrowserRequest() {
    if (BrowserRequest.request.value != null && _index != 3) {
      setState(() => _index = 3);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = CommsScope.of(context);

    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: IndexedStack(
              index: _index,
              children: const [
                ConversationsScreen(),
                ContactsScreen(),
                FilesScreen(),
                BrowserScreen(),
                SettingsScreen(),
              ],
            ),
          ),
          ValueListenableBuilder(
            valueListenable: controller.channel.status,
            builder: (context, status, _) {
              if (status == 'online') return const SizedBox.shrink();
              return Container(
                width: double.infinity,
                color: Theme.of(context).colorScheme.inverseSurface,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Text(
                  status == 'connecting'
                      ? L.t('Connecting…', ru: 'Подключение…')
                      : status,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onInverseSurface,
                    fontSize: 12,
                  ),
                ),
              );
            },
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.chat_bubble_outline),
            selectedIcon: const Icon(Icons.chat_bubble),
            label: L.t('Chats', ru: 'Чаты'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.people_outline),
            selectedIcon: const Icon(Icons.people),
            label: L.t('People', ru: 'Контакты'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.folder_outlined),
            selectedIcon: const Icon(Icons.folder),
            label: L.t('Files', ru: 'Файлы'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.public),
            selectedIcon: const Icon(Icons.public),
            label: L.t('Browse', ru: 'Браузер'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: const Icon(Icons.settings),
            label: L.t('Settings', ru: 'Настройки'),
          ),
        ],
      ),
    );
  }
}
