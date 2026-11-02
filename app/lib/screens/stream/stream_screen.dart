import 'dart:async';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/localizations.dart';
import '../../models.dart';
import '../../services/comms_controller.dart';
import '../../widgets/user_avatar.dart';
import '../account/account_switcher.dart';
import 'stream_room_screen.dart';

/// The Stream tab: a Twitch-like live directory plus the broadcaster's own
/// channel profile (title, description, game, visibility, moderation).
class StreamScreen extends StatefulWidget {
  const StreamScreen({super.key});

  @override
  State<StreamScreen> createState() => _StreamScreenState();
}

class _StreamScreenState extends State<StreamScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _game = TextEditingController();

  String _visibility = 'public';
  int _slowMode = 0;
  String _quality = '720p';
  bool _saving = false;
  bool _working = false;
  bool _started = false;
  String? _accountId;
  CommsController? _controller;

  @override
  void initState() {
    super.initState();
    _controller = CommsScope.read(context);
    _accountId = _controller!.activeAccountId;
    _controller!.addListener(_onControllerChanged);
    _game.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _controller?.removeListener(_onControllerChanged);
    _tabs.dispose();
    _title.dispose();
    _description.dispose();
    _game.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    final id = _controller?.activeAccountId;
    if (id == _accountId) return;
    _accountId = id;
    _started = false;
    if (mounted) {
      setState(() {
        _title.clear();
        _description.clear();
        _game.clear();
      });
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final controller = CommsScope.read(context);
    await controller.refreshStreamTab();
    if (!mounted) return;
    _syncForm(controller.streamChannel);
  }

  void _syncForm(StreamChannel? channel) {
    if (channel == null) return;
    _title.text = channel.title;
    _description.text = channel.description;
    _game.text = channel.game;
    setState(() {
      _visibility = channel.visibility;
      _slowMode = channel.slowMode;
      _started = true;
    });
  }

  Future<void> _save({bool silent = false}) async {
    final controller = CommsScope.read(context);
    if (_title.text.trim().isEmpty) {
      controller.showSnack(
        L.t('Set a stream title first.', ru: 'Сначала задайте название трансляции.'),
      );
      return;
    }
    setState(() => _saving = true);
    final ok = await controller.saveStreamChannel(
      title: _title.text.trim(),
      description: _description.text.trim(),
      game: _game.text.trim(),
      visibility: _visibility,
      slowMode: _slowMode,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok && !silent) {
      controller.showSnack(L.t('Channel saved', ru: 'Канал сохранён'));
    }
  }

  Future<void> _goLive() async {
    final controller = CommsScope.read(context);
    if (_title.text.trim().isEmpty) {
      controller.showSnack(
        L.t('Set a stream title first.', ru: 'Сначала задайте название трансляции.'),
      );
      return;
    }
    setState(() => _working = true);
    final saved = await controller.saveStreamChannel(
      title: _title.text.trim(),
      description: _description.text.trim(),
      game: _game.text.trim(),
      visibility: _visibility,
      slowMode: _slowMode,
    );
    if (!saved) {
      if (mounted) setState(() => _working = false);
      return;
    }
    final live = await controller.goLive(quality: _quality);
    if (!mounted) return;
    setState(() => _working = false);
    if (live) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => const StreamRoomScreen(broadcaster: true),
        ),
      );
    }
  }

  Future<void> _endStream() async {
    final controller = CommsScope.read(context);
    final confirmed = await _confirm(
      title: L.t('End the stream?', ru: 'Завершить трансляцию?'),
      message: L.t(
        'Every viewer is disconnected and the stream chat is archived.',
        ru: 'Все зрители будут отключены, а чат трансляции архивирован.',
      ),
      action: L.t('End stream', ru: 'Завершить'),
    );
    if (!confirmed) return;
    await controller.endMyStream();
    if (mounted) await _load();
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String action,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(L.t('Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _openStream(CommsController controller, StreamInfo info) async {
    if (info.isMine) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => const StreamRoomScreen(broadcaster: true),
        ),
      );
      return;
    }
    if (controller.streaming) {
      controller.showSnack(
        L.t(
          'Leave the current stream first.',
          ru: 'Сначала покиньте текущую трансляцию.',
        ),
      );
      return;
    }
    final ok = await controller.joinStream(info);
    if (!ok || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const StreamRoomScreen(broadcaster: false),
      ),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final controller = CommsScope.of(context);
    final theme = Theme.of(context);
    final live = controller.myStream;

    return Scaffold(
      appBar: AppBar(
        leading: const AccountButton(),
        title: Text(L.t('Stream', ru: 'Трансляции')),
        actions: [
          IconButton(
            tooltip: L.t('Refresh', ru: 'Обновить'),
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(
              icon: const Icon(Icons.live_tv),
              text: L.t('Live now', ru: 'В эфире'),
            ),
            Tab(
              icon: const Icon(Icons.podcasts),
              text: L.t('My channel', ru: 'Мой канал'),
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _directory(controller, theme),
          _channel(controller, theme, live),
        ],
      ),
    );
  }

  // ---- directory ----------------------------------------------------------

  Widget _directory(CommsController controller, ThemeData theme) {
    if (controller.streamLoading && controller.streamDirectory.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (controller.streamDirectory.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 80, 24, 24),
              child: Column(
                children: [
                  Icon(
                    Icons.live_tv_outlined,
                    size: 64,
                    color: theme.colorScheme.outline,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    L.t('No one is live right now', ru: 'Сейчас никто не в эфире'),
                    style: theme.textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    L.t(
                      'Be the first to start a stream.',
                      ru: 'Станьте первым, кто начнёт трансляцию.',
                    ),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: () => _tabs.animateTo(1),
                    icon: const Icon(Icons.podcasts),
                    label: Text(L.t('Set up my channel', ru: 'Настроить канал')),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: controller.streamDirectory.length,
        separatorBuilder: (_, _) => const SizedBox(height: 4),
        itemBuilder: (context, index) {
          final info = controller.streamDirectory[index];
          return _StreamCard(info: info, onTap: () => _openStream(controller, info));
        },
      ),
    );
  }

  // ---- my channel ---------------------------------------------------------

  Widget _channel(CommsController controller, ThemeData theme, StreamInfo? live) {
    final watching = controller.watching;
    final suggestions = controller.streamGames
        .where((g) => g.toLowerCase() != _game.text.trim().toLowerCase())
        .where(
          (g) =>
              _game.text.trim().isEmpty ||
              g.toLowerCase().contains(_game.text.trim().toLowerCase()),
        )
        .take(6)
        .toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        if (live != null) ...[
          _LiveBanner(
            stream: live,
            onOpen: () => _openStream(controller, live),
            onEnd: _endStream,
          ),
          const SizedBox(height: 12),
        ] else if (watching != null) ...[
          Card(
            color: theme.colorScheme.secondaryContainer,
            child: ListTile(
              leading: const Icon(Icons.visibility),
              title: Text(watching.title),
              subtitle: Text(
                L.t(
                  'Watching ${watching.broadcaster.displayName}',
                  ru: 'Вы смотрите ${watching.broadcaster.displayName}',
                ),
              ),
              trailing: FilledButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const StreamRoomScreen(broadcaster: false),
                  ),
                ),
                child: Text(L.t('Open', ru: 'Открыть')),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (!_started && controller.streamLoading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  L.t('Channel details', ru: 'Данные канала'),
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _title,
                  maxLength: 80,
                  decoration: InputDecoration(
                    labelText: L.t('Stream title', ru: 'Название трансляции'),
                    hintText: L.t(
                      'Speedrun night — Any% attempts',
                      ru: 'Вечер спидранов — попытки Any%',
                    ),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _description,
                  maxLength: 500,
                  maxLines: 3,
                  minLines: 2,
                  decoration: InputDecoration(
                    labelText: L.t('Description', ru: 'Описание'),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _game,
                  maxLength: 60,
                  decoration: InputDecoration(
                    labelText: L.t('Game', ru: 'Игра'),
                    hintText: L.t('e.g. Celeste', ru: 'например Celeste'),
                    border: const OutlineInputBorder(),
                    suffixIcon: const Icon(Icons.sports_esports),
                  ),
                ),
                if (suggestions.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final game in suggestions)
                          ActionChip(
                            label: Text(game),
                            onPressed: () => _game.text = game,
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _visibility,
                  decoration: InputDecoration(
                    labelText: L.t('Visibility', ru: 'Видимость'),
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    DropdownMenuItem(
                      value: 'public',
                      child: Text(L.t('Public — listed', ru: 'Публично — в списке')),
                    ),
                    DropdownMenuItem(
                      value: 'unlisted',
                      child: Text(L.t('Unlisted — link only', ru: 'Скрыто — только по ссылке')),
                    ),
                    DropdownMenuItem(
                      value: 'contacts',
                      child: Text(L.t('Contacts only', ru: 'Только контакты')),
                    ),
                  ],
                  onChanged: (v) => setState(() => _visibility = v ?? 'public'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: _slowMode,
                  decoration: InputDecoration(
                    labelText: L.t('Slow mode', ru: 'Медленный режим'),
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    DropdownMenuItem(value: 0, child: Text(L.t('Off', ru: 'Выкл.'))),
                    DropdownMenuItem(value: 3, child: Text(L.t('3 seconds', ru: '3 секунды'))),
                    DropdownMenuItem(value: 10, child: Text(L.t('10 seconds', ru: '10 секунд'))),
                    DropdownMenuItem(value: 30, child: Text(L.t('30 seconds', ru: '30 секунд'))),
                  ],
                  onChanged: (v) => setState(() => _slowMode = v ?? 0),
                ),
                const SizedBox(height: 12),
                Text(
                  L.t('Stream quality', ru: 'Качество трансляции'),
                  style: theme.textTheme.labelLarge,
                ),
                const SizedBox(height: 6),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: '480p', label: Text('480p')),
                    ButtonSegment(value: '720p', label: Text('720p')),
                  ],
                  selected: {_quality},
                  onSelectionChanged: (v) => setState(() => _quality = v.first),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _saving ? null : () => _save(),
                        icon: _saving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.save_outlined),
                        label: Text(L.t('Save channel', ru: 'Сохранить канал')),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed:
                            (live != null || watching != null || _working)
                                ? null
                                : _goLive,
                        icon: _working
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.podcasts),
                        label: Text(L.t('Go live', ru: 'В эфир')),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (live != null) ...[
          const SizedBox(height: 12),
          _ModerationPanel(stream: live),
        ],
      ],
    );
  }
}

// ---- widgets --------------------------------------------------------------

class _StreamCard extends StatelessWidget {
  const _StreamCard({required this.info, required this.onTap});

  final StreamInfo info;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final full = info.isFull && !info.isViewer;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: full ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              UserAvatar(
                name: info.broadcaster.displayName,
                seed: info.broadcaster.id,
                isVerified: info.broadcaster.isVerified,
                radius: 26,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      info.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      info.broadcaster.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (info.game.isNotEmpty)
                          Chip(
                            avatar: const Icon(Icons.sports_esports, size: 16),
                            label: Text(info.game),
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.visibility, size: 16),
                            const SizedBox(width: 4),
                            Text(
                              '${info.viewerCount}/${info.maxViewers}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                        if (info.visibility != 'public')
                          Icon(
                            info.visibility == 'unlisted'
                                ? Icons.link
                                : Icons.group_outlined,
                            size: 16,
                            color: theme.colorScheme.outline,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (full)
                Text(
                  L.t('Full', ru: 'Занято'),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                )
              else
                const _LiveBadge(),
            ],
          ),
        ),
      ),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.red,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        L.t('LIVE', ru: 'ЭФИР'),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _LiveBanner extends StatelessWidget {
  const _LiveBanner({
    required this.stream,
    required this.onOpen,
    required this.onEnd,
  });

  final StreamInfo stream;
  final VoidCallback onOpen;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const _LiveBadge(),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    stream.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              L.t(
                '${stream.viewerCount} of ${stream.maxViewers} viewers',
                ru: '${stream.viewerCount} из ${stream.maxViewers} зрителей',
              ),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onOpen,
                    icon: const Icon(Icons.open_in_new),
                    label: Text(L.t('Open stream', ru: 'Открыть эфир')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: onEnd,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: Text(L.t('End stream', ru: 'Завершить')),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ModerationPanel extends StatelessWidget {
  const _ModerationPanel({required this.stream});

  final StreamInfo stream;

  @override
  Widget build(BuildContext context) {
    final controller = CommsScope.of(context);
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            ExpansionTile(
              leading: const Icon(Icons.people_outline),
              title: Text(
                L.t(
                  'Viewers (${controller.streamViewers.length})',
                  ru: 'Зрители (${controller.streamViewers.length})',
                ),
              ),
              children: [
                if (controller.streamViewers.isEmpty)
                  ListTile(
                    title: Text(
                      L.t('Nobody is watching yet', ru: 'Пока никто не смотрит'),
                    ),
                  ),
                for (final viewer in controller.streamViewers)
                  ListTile(
                    leading: UserAvatar(
                      name: viewer.user.displayName,
                      seed: viewer.user.id,
                      isVerified: viewer.user.isVerified,
                      radius: 18,
                    ),
                    title: Text(viewer.user.displayName),
                    subtitle: viewer.online
                        ? Text(L.t('watching now', ru: 'смотрит сейчас'))
                        : Text(L.t('offline', ru: 'не в сети')),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: L.t('Kick', ru: 'Выгнать'),
                          icon: const Icon(Icons.logout),
                          onPressed: () => controller.kickViewer(viewer.user.id),
                        ),
                        IconButton(
                          tooltip: L.t('Ban from channel', ru: 'Забанить на канале'),
                          icon: const Icon(Icons.block),
                          onPressed: () => controller.banViewer(viewer.user.id),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            ExpansionTile(
              leading: const Icon(Icons.shield_outlined),
              title: Text(
                L.t(
                  'Moderators (${controller.streamMods.length})',
                  ru: 'Модераторы (${controller.streamMods.length})',
                ),
              ),
              children: [
                if (controller.streamMods.isEmpty)
                  ListTile(
                    title: Text(
                      L.t(
                        'Add a moderator from your viewers',
                        ru: 'Назначьте модератора из зрителей',
                      ),
                    ),
                  ),
                for (final mod in controller.streamMods)
                  ListTile(
                    leading: UserAvatar(
                      name: mod.displayName,
                      seed: mod.id,
                      radius: 18,
                    ),
                    title: Text(mod.displayName),
                    trailing: IconButton(
                      tooltip: L.t('Remove moderator', ru: 'Снять модератора'),
                      icon: const Icon(Icons.remove_moderator_outlined),
                      onPressed: () => controller.removeStreamMod(mod),
                    ),
                  ),
                if (controller.streamViewers
                    .where((v) => !controller.streamMods
                        .any((m) => m.id == v.user.id))
                    .isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        L.t(
                          'Tap a viewer to promote them',
                          ru: 'Нажмите на зрителя, чтобы назначить его',
                        ),
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ),
              ],
            ),
            ExpansionTile(
              leading: const Icon(Icons.block),
              title: Text(
                L.t(
                  'Banned (${controller.streamBans.length})',
                  ru: 'Забанены (${controller.streamBans.length})',
                ),
              ),
              children: [
                if (controller.streamBans.isEmpty)
                  ListTile(
                    title: Text(
                      L.t('No one is banned', ru: 'Никто не забанен'),
                    ),
                  ),
                for (final banned in controller.streamBans)
                  ListTile(
                    leading: UserAvatar(
                      name: banned.displayName,
                      seed: banned.id,
                      radius: 18,
                    ),
                    title: Text(banned.displayName),
                    trailing: TextButton(
                      onPressed: () => controller.unbanViewer(banned.id),
                      child: Text(L.t('Unban', ru: 'Разбанить')),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
