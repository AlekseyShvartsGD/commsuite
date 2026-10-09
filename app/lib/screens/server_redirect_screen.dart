import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/app_config.dart';
import '../../core/localizations.dart';

/// Shown instead of the login page while a remembered session is being
/// restored against the saved server (including while the server is being
/// auto-started on Windows).
class ServerRedirectScreen extends StatelessWidget {
  const ServerRedirectScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = CommsScope.of(context);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.wifi_tethering,
                size: 64,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 20),
              Text(
                L.t(
                  'We are redirecting you to the server you saved.',
                  ru: 'Перенаправление на сохранённый вами сервер.',
                ),
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                AppConfig.serverUrl,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 28),
              const CircularProgressIndicator(),
              const SizedBox(height: 36),
              TextButton(
                onPressed: controller.startFreshSession,
                child: Text(
                  L.t(
                    'Use a different account',
                    ru: 'Использовать другой аккаунт',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
