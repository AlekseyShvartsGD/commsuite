import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/account.dart';
import '../../core/localizations.dart';
import '../../services/comms_controller.dart';
import '../../widgets/user_avatar.dart';
import '../auth_screen.dart';

/// Opens the account drawer: switch between saved accounts, add one, or sign
/// the active one out.
Future<void> showAccountSwitcher(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const AccountSwitcherSheet(),
  );
}

class AccountSwitcherSheet extends StatelessWidget {
  const AccountSwitcherSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = CommsScope.of(context);
    final theme = Theme.of(context);
    final accounts = controller.accounts;
    final activeId = controller.activeAccountId;

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      L.t('Accounts', ru: 'Аккаунты'),
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: L.t('Add account', ru: 'Добавить аккаунт'),
                    icon: const Icon(Icons.person_add_alt_1_outlined),
                    onPressed: () => _addAccount(context),
                  ),
                ],
              ),
            ),
            if (accounts.isEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  L.t('No saved accounts', ru: 'Нет сохранённых аккаунтов'),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            for (final account in accounts)
              _AccountTile(
                account: account,
                active: account.id == activeId,
                unread: controller.unreadForAccount(account.id),
                showServer: accounts
                    .map((a) => a.serverHost)
                    .toSet()
                    .length > 1,
              ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.add),
              title: Text(L.t('Add account', ru: 'Добавить аккаунт')),
              subtitle: Text(
                L.t(
                  'Sign in to another account on this device',
                  ru: 'Войти в другой аккаунт на этом устройстве',
                ),
              ),
              onTap: () => _addAccount(context),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _addAccount(BuildContext context) {
    final nav = Navigator.of(context, rootNavigator: true);
    Navigator.of(context).pop();
    nav.push(
      MaterialPageRoute<void>(
        builder: (_) => const AuthScreen(addingAccount: true),
      ),
    );
  }
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({
    required this.account,
    required this.active,
    required this.unread,
    required this.showServer,
  });

  final AccountRecord account;
  final bool active;
  final int unread;
  final bool showServer;

  @override
  Widget build(BuildContext context) {
    final controller = CommsScope.of(context);
    final theme = Theme.of(context);
    final subtitle = showServer
        ? '${account.handle} · ${account.serverHost}'
        : account.handle;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          UserAvatar(
            name: account.label,
            seed: account.username,
            isVerified: account.verified,
            radius: 22,
          ),
          if (unread > 0 && !active)
            Positioned(
              right: -6,
              top: -4,
              child: _Badge(count: unread),
            ),
        ],
      ),
      title: Text(
        account.label,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(subtitle, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (active)
            Icon(Icons.check_circle, color: theme.colorScheme.primary)
          else if (unread > 0)
            _Badge(count: unread),
          PopupMenuButton<String>(
            tooltip: L.t('Account options', ru: 'Параметры аккаунта'),
            onSelected: (value) {
              if (value == 'signout') _confirmRemove(context, controller);
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'signout',
                child: Text(
                  active
                      ? L.t('Sign out', ru: 'Выйти')
                      : L.t('Remove account', ru: 'Удалить аккаунт'),
                ),
              ),
            ],
          ),
        ],
      ),
      onTap: active
          ? () => Navigator.of(context).pop()
          : () {
              final nav = Navigator.of(context);
              nav.pop();
              controller.switchAccount(account.id);
            },
    );
  }

  Future<void> _confirmRemove(
    BuildContext context,
    CommsController controller,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          active
              ? L.t('Sign out?', ru: 'Выйти?')
              : L.t('Remove account?', ru: 'Удалить аккаунт?'),
        ),
        content: Text(
          L.t(
            '${account.label} will be removed from this device. '
                'Other accounts stay signed in.',
            ru: '${account.label} будет удалён с этого устройства. '
                'Остальные аккаунты останутся в системе.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(L.t('Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(L.t('Remove', ru: 'Удалить')),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    Navigator.of(context).pop(); // close the sheet
    await controller.removeAccount(account.id);
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      constraints: const BoxConstraints(minWidth: 18),
      decoration: BoxDecoration(
        color: theme.colorScheme.error,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: theme.colorScheme.onError,
          fontSize: 11,
          height: 1.3,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Small avatar in an app bar that opens [showAccountSwitcher]. Shows a dot
/// while another signed-in account has unread messages.
class AccountButton extends StatelessWidget {
  const AccountButton({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = CommsScope.of(context);
    final user = controller.user;
    if (user == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final othersUnread = controller.otherAccountsUnread;

    return Padding(
      padding: const EdgeInsets.only(left: 8, right: 4),
      child: Tooltip(
        message: L.t('Accounts', ru: 'Аккаунты'),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => showAccountSwitcher(context),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              UserAvatar(
                name: user.displayName,
                seed: user.username,
                isVerified: user.isVerified,
                radius: 18,
              ),
              if (controller.accounts.length > 1)
                Positioned(
                  right: -1,
                  top: -1,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: othersUnread > 0
                          ? theme.colorScheme.error
                          : theme.colorScheme.primary,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: theme.colorScheme.surface,
                        width: 2,
                      ),
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

/// Settings entry: shows the active account and how many others are saved.
class AccountsCard extends StatelessWidget {
  const AccountsCard({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = CommsScope.of(context);
    final active = controller.activeAccount;
    final count = controller.accounts.length;

    return Card(
      child: ListTile(
        leading: const Icon(Icons.manage_accounts_outlined),
        title: Text(L.t('Accounts', ru: 'Аккаунты')),
        subtitle: Text(
          active == null
              ? L.t('Add an account', ru: 'Добавьте аккаунт')
              : L.t(
                  '${active.handle} · $count saved',
                  ru: '${active.handle} · сохранено: $count',
                ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (controller.otherAccountsUnread > 0)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _Badge(count: controller.otherAccountsUnread),
              ),
            const Icon(Icons.chevron_right),
          ],
        ),
        onTap: () => showAccountSwitcher(context),
      ),
    );
  }
}
