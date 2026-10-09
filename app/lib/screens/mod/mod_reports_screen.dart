import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app.dart';
import '../../core/api.dart';
import '../../models.dart';
import '../../core/localizations.dart';

class ModReportsScreen extends StatefulWidget {
  const ModReportsScreen({super.key});

  @override
  State<ModReportsScreen> createState() => _ModReportsScreenState();
}

class _ModReportsScreenState extends State<ModReportsScreen> {
  List<Report> _reports = [];
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final token = CommsScope.read(context).token;
    if (token == null) return;
    setState(() => _loading = true);
    try {
      final reports = await Api.reports(token);
      if (!mounted) return;
      setState(() {
        _reports = reports;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.t(
              'Failed to load reports: ${e.message}',
              ru: 'Не удалось загрузить жалобы: ${e.message}',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _resolve(Report report) async {
    final token = CommsScope.read(context).token;
    if (token == null || _busy) return;
    setState(() => _busy = true);
    try {
      await Api.resolveReport(token, report.reporterId, report.targetId);
      if (!mounted) return;
      setState(
        () => _reports.removeWhere(
          (r) =>
              r.reporterId == report.reporterId &&
              r.targetId == report.targetId,
        ),
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L.t('Report resolved.', ru: 'Жалоба рассмотрена.')),
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.t('Failed: ${e.message}', ru: 'Ошибка: ${e.message}'),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _ban(Report report) async {
    final token = CommsScope.read(context).token;
    if (token == null || _busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.gavel, color: Colors.red),
        title: Text(
          L.t(
            'Ban @${report.targetUsername}?',
            ru: 'Заблокировать @${report.targetUsername}?',
          ),
        ),
        content: Text(
          L.t(
            '${report.targetDisplay} will be locked out of their account. '
            'They will not be able to log in or connect until unbanned.',
            ru:
                '${report.targetDisplay} потеряет доступ к аккаунту. '
                'Пользователь не сможет войти и подключиться, пока блокировка не будет снята.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(L.t('Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: Text(L.t('Ban user', ru: 'Заблокировать пользователя')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await Api.setBan(token, report.targetId, banned: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.t(
              '@${report.targetUsername} banned.',
              ru: '@${report.targetUsername} заблокирован.',
            ),
          ),
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.t('Failed: ${e.message}', ru: 'Ошибка: ${e.message}'),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _when(DateTime time) {
    final l = time.toLocal();
    final now = DateTime.now();
    final diff = now.difference(l);
    if (diff.inMinutes < 1) return L.t('just now', ru: 'только что');
    if (diff.inMinutes < 60) {
      return L.plural(
        diff.inMinutes,
        enOne: '${diff.inMinutes}m ago',
        enMany: '${diff.inMinutes}m ago',
        ruOne: '${diff.inMinutes} мин назад',
        ruFew: '${diff.inMinutes} мин назад',
        ruMany: '${diff.inMinutes} мин назад',
      );
    }
    if (diff.inHours < 24) {
      return L.plural(
        diff.inHours,
        enOne: '${diff.inHours}h ago',
        enMany: '${diff.inHours}h ago',
        ruOne: '${diff.inHours} ч назад',
        ruFew: '${diff.inHours} ч назад',
        ruMany: '${diff.inHours} ч назад',
      );
    }
    if (diff.inDays < 7) {
      return L.plural(
        diff.inDays,
        enOne: '${diff.inDays}d ago',
        enMany: '${diff.inDays}d ago',
        ruOne: '${diff.inDays} дн назад',
        ruFew: '${diff.inDays} дн назад',
        ruMany: '${diff.inDays} дн назад',
      );
    }
    return DateFormat('dd MMM yyyy').format(l);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(L.t('Moderation', ru: 'Модерация')),
        actions: [
          IconButton(
            tooltip: L.t('Refresh', ru: 'Обновить'),
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _reports.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.verified_outlined,
                    size: 56,
                    color: theme.colorScheme.outline,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    L.t(
                      'No reports to review',
                      ru: 'Нет жалоб для рассмотрения',
                    ),
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    L.t('All clear for now.', ru: 'Пока всё чисто.'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                itemCount: _reports.length,
                itemBuilder: (context, i) {
                  final r = _reports[i];
                  return Card(
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              CircleAvatar(
                                radius: 18,
                                foregroundImage: null,
                                child: Text(
                                  r.reporterDisplay.isNotEmpty
                                      ? r.reporterDisplay[0].toUpperCase()
                                      : '?',
                                  style: const TextStyle(fontSize: 14),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text.rich(
                                      TextSpan(
                                        children: [
                                          TextSpan(
                                            text: r.reporterDisplay.isEmpty
                                                ? r.reporterUsername
                                                : r.reporterDisplay,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          TextSpan(
                                            text: L.t(
                                              ' reported ',
                                              ru: ' пожаловался ',
                                            ),
                                          ),
                                          TextSpan(
                                            text: r.targetDisplay.isEmpty
                                                ? r.targetUsername
                                                : r.targetDisplay,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Text(
                                      '@${r.reporterUsername} → @${r.targetUsername} · ${_when(r.createdAt)}',
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme.colorScheme.outline,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          if (r.reason.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color:
                                    theme.colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                r.reason,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 10),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              OutlinedButton.icon(
                                onPressed: _busy ? null : () => _resolve(r),
                                icon: const Icon(Icons.done, size: 18),
                                label: Text(L.t('Resolve', ru: 'Решить')),
                              ),
                              const SizedBox(width: 8),
                              FilledButton.tonalIcon(
                                onPressed: _busy ? null : () => _ban(r),
                                style: FilledButton.styleFrom(
                                  backgroundColor:
                                      theme.colorScheme.errorContainer,
                                  foregroundColor:
                                      theme.colorScheme.onErrorContainer,
                                ),
                                icon: const Icon(Icons.gavel, size: 18),
                                label: Text(
                                  L.t(
                                    'Ban @${r.targetUsername}',
                                    ru: 'Заблокировать @${r.targetUsername}',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}
