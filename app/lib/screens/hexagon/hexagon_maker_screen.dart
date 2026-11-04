import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app.dart';
import '../../core/localizations.dart';
import '../../hexagon/hexagon_exporter.dart';
import '../../hexagon/hexagon_generator.dart';
import '../../hexagon/hexagon_models.dart';
import '../../hexagon/hexagon_store.dart';
import 'hexagon_preview.dart';

class HexMapMakerScreen extends StatefulWidget {
  const HexMapMakerScreen({super.key});

  @override
  State<HexMapMakerScreen> createState() => _HexMapMakerScreenState();
}

class _HexMapMakerScreenState extends State<HexMapMakerScreen> {
  final _packName = TextEditingController();
  final _levelName = TextEditingController();
  final _author = TextEditingController();
  final _description = TextEditingController();
  final _endingMessage = TextEditingController();

  HexMapDraft _draft = HexMapDraft.defaults();
  Timer? _saveTimer;
  bool _loaded = false;
  bool _exporting = false;
  bool _rotatePreview = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final user = CommsScope.read(context).user;
    final fallbackAuthor = (user?.displayName ?? user?.username ?? '').trim();
    HexMapDraft? saved;
    try {
      saved = await HexDraftStore.load();
    } catch (_) {
      saved = null;
    }
    final draft = saved ?? HexMapDraft.defaults(author: fallbackAuthor);
    if (!mounted) return;
    setState(() {
      _draft = draft;
      _loaded = true;
      _syncControllers(draft);
    });
  }

  void _syncControllers(HexMapDraft draft) {
    _packName.text = draft.packName;
    _levelName.text = draft.levelName;
    _author.text = draft.author;
    _description.text = draft.description;
    _endingMessage.text = draft.ending.message;
  }

  void _update(HexMapDraft next) {
    setState(() => _draft = next);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(HexDraftStore.save(_draft));
    });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    unawaited(HexDraftStore.save(_draft));
    _packName.dispose();
    _levelName.dispose();
    _author.dispose();
    _description.dispose();
    _endingMessage.dispose();
    super.dispose();
  }

  List<String> get _errors => _draft.validate();

  Future<void> _reset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          L.t('Start over?', ru: 'Начать заново?'),
        ),
        content: Text(
          L.t(
            'This clears the saved draft and returns every slider to its default.',
            ru: 'Сохранённый черновик будет очищен, а все ползунки вернутся к значениям по умолчанию.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(L.t('Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(L.t('Reset', ru: 'Сбросить')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final next = HexMapDraft.defaults(author: _draft.author);
    await HexDraftStore.clear();
    if (!mounted) return;
    setState(() {
      _draft = next;
      _syncControllers(next);
    });
  }

  bool _guardExport() {
    if (_errors.isEmpty) return true;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_localizedError(_errors.first)),
      ),
    );
    return false;
  }

  Future<void> _saveZip() async {
    if (!_guardExport()) return;
    setState(() => _exporting = true);
    try {
      final result = await HexPackExporter.exportZip(_draft);
      if (!mounted) return;
      if (result == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.t(
              'Saved ${_displayPath(result.path)}',
              ru: 'Сохранено: ${_displayPath(result.path)}',
            ),
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.t('Export failed: $error', ru: 'Не удалось экспортировать: $error'),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _exportFolder() async {
    if (!_guardExport()) return;
    setState(() => _exporting = true);
    try {
      final result = await HexPackExporter.exportFolder(_draft);
      if (!mounted) return;
      if (result == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.t(
              'Pack folder written to ${_displayPath(result.path)}',
              ru: 'Папка пака записана в ${_displayPath(result.path)}',
            ),
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.t('Export failed: $error', ru: 'Не удалось экспортировать: $error'),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  String _displayPath(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri != null && uri.scheme == 'file') return uri.toFilePath();
    return raw;
  }

  String _localizedError(String en) {
    if (!L.isRu) return en;
    return switch (en) {
      'Pack name is required.' => 'Укажите название пака.',
      'Level name is required.' => 'Укажите название уровня.',
      'Author is required.' => 'Укажите автора.',
      'Description must be 300 characters or fewer.' =>
        'Описание должно быть не длиннее 300 символов.',
      'Sides must be between 3 and 10.' => 'Число сторон должно быть от 3 до 10.',
      'Speed multiplier must be between 0.4 and 4.0.' =>
        'Множитель скорости должен быть от 0.4 до 4.0.',
      'Increment time must be between 3 and 180 seconds.' =>
        'Время до следующего уровня должно быть от 3 до 180 секунд.',
      'Add at least one pattern to the sequence.' =>
        'Добавьте хотя бы один паттерн в последовательность.',
      'Ending time must be between 5 and 3600 seconds.' =>
        'Время концовки должно быть от 5 до 3600 секунд.',
      'Ending message must be 120 characters or fewer.' =>
        'Сообщение концовки должно быть не длиннее 120 символов.',
      'Enable at least one ending effect.' =>
        'Включите хотя бы один эффект концовки.',
      _ => en,
    };
  }

  Future<void> _addPattern() async {
    final kind = await showModalBottomSheet<HexPatternKind>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                L.t('Add a pattern', ru: 'Добавить паттерн'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final kind in HexPatternKind.values)
              ListTile(
                leading: Icon(hexPatternIcon(kind)),
                title: Text(hexPatternLabel(kind)),
                subtitle: Text(hexPatternDescription(kind)),
                onTap: () => Navigator.of(context).pop(kind),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (kind == null || !mounted) return;
    _update(
      _draft.copyWith(
        patterns: [
          ..._draft.patterns,
          HexPatternSelection(kind: kind),
        ],
      ),
    );
  }

  void _reorderPatterns(int oldIndex, int newIndex) {
    final patterns = List<HexPatternSelection>.of(_draft.patterns);
    final item = patterns.removeAt(oldIndex);
    patterns.insert(newIndex, item);
    _update(_draft.copyWith(patterns: patterns));
  }

  void _removePattern(HexPatternSelection pattern) {
    _update(
      _draft.copyWith(
        patterns: _draft.patterns
            .where((candidate) => candidate.id != pattern.id)
            .toList(),
      ),
    );
  }

  Future<void> _showLua() async {
    final pack = HexPackBuilder.build(_draft);
    final lua = pack.textFiles['Scripts/${pack.levelId}.lua'] ?? '';
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(L.t('Generated Lua', ru: 'Сгенерированный Lua')),
        content: SizedBox(
          width: 680,
          height: 520,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                lua,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: lua));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    L.t('Lua copied', ru: 'Lua скопирован'),
                  ),
                ),
              );
            },
            icon: const Icon(Icons.copy, size: 18),
            label: Text(L.t('Copy', ru: 'Копировать')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(L.t('Close', ru: 'Закрыть')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          L.t('Open Hexagon map maker', ru: 'Создатель карт Open Hexagon'),
        ),
        actions: [
          IconButton(
            tooltip: L.t('Start over', ru: 'Начать заново'),
            onPressed: _loaded ? _reset : null,
            icon: const Icon(Icons.restart_alt),
          ),
          IconButton(
            tooltip: L.t('Save .zip', ru: 'Сохранить .zip'),
            onPressed: _loaded && !_exporting ? _saveZip : null,
            icon: _exporting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.archive_outlined),
          ),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : DefaultTabController(
              length: 4,
              child: Column(
                children: [
                  TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    tabs: [
                      Tab(
                        icon: const Icon(Icons.tune),
                        text: L.t('Design', ru: 'Дизайн'),
                      ),
                      Tab(
                        icon: const Icon(Icons.route_outlined),
                        text: L.t('Patterns', ru: 'Паттерны'),
                      ),
                      Tab(
                        icon: const Icon(Icons.nightlight_outlined),
                        text: L.t('Ending', ru: 'Концовка'),
                      ),
                      Tab(
                        icon: const Icon(Icons.ios_share),
                        text: L.t('Export', ru: 'Экспорт'),
                      ),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _designTab(context),
                        _patternsTab(context),
                        _endingTab(context),
                        _exportTab(context),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _designTab(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        HexPreview(
          draft: _draft,
          rotateCamera: _rotatePreview,
          height: 230,
        ),
        const SizedBox(height: 8),
        Card(
          child: SwitchListTile(
            secondary: const Icon(Icons.threesixty),
            title: Text(L.t('Camera orbit', ru: 'Вращение камеры')),
            subtitle: Text(
              L.t(
                'Orbit the arena like the game. Drag the preview to look around; double-tap to reset.',
                ru: 'Арена вращается как в игре. Потяните превью, чтобы осмотреться; двойной тап сбрасывает угол.',
              ),
            ),
            value: _rotatePreview,
            onChanged: (value) => setState(() => _rotatePreview = value),
          ),
        ),
        const SizedBox(height: 16),
        Text(L.t('Identity', ru: 'Название и автор'), style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        TextField(
          controller: _packName,
          maxLength: 60,
          decoration: InputDecoration(
            labelText: L.t('Pack name', ru: 'Название пака'),
            helperText: L.t(
              'Folder: ${_draft.packSlug}',
              ru: 'Папка: ${_draft.packSlug}',
            ),
            prefixIcon: const Icon(Icons.inventory_2_outlined),
            border: const OutlineInputBorder(),
          ),
          onChanged: (value) => _update(_draft.copyWith(packName: value)),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: _levelName,
          maxLength: 60,
          decoration: InputDecoration(
            labelText: L.t('Level name', ru: 'Название уровня'),
            helperText: L.t(
              'Level id: ${_draft.levelSlug}',
              ru: 'ID уровня: ${_draft.levelSlug}',
            ),
            prefixIcon: const Icon(Icons.hexagon_outlined),
            border: const OutlineInputBorder(),
          ),
          onChanged: (value) => _update(_draft.copyWith(levelName: value)),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: _author,
          maxLength: 80,
          decoration: InputDecoration(
            labelText: L.t('Author', ru: 'Автор'),
            prefixIcon: const Icon(Icons.person_outline),
            border: const OutlineInputBorder(),
          ),
          onChanged: (value) => _update(_draft.copyWith(author: value)),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: _description,
          maxLength: 300,
          minLines: 2,
          maxLines: 4,
          decoration: InputDecoration(
            labelText: L.t('Description', ru: 'Описание'),
            alignLabelWithHint: true,
            prefixIcon: const Icon(Icons.notes_outlined),
            border: const OutlineInputBorder(),
          ),
          onChanged: (value) => _update(_draft.copyWith(description: value)),
        ),
        const SizedBox(height: 16),
        Text(L.t('Palette', ru: 'Палитра'), style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final palette in HexPalette.values)
              ChoiceChip(
                label: Text(hexPaletteLabel(palette)),
                selected: _draft.palette == palette,
                onSelected: (_) => _update(_draft.copyWith(palette: palette)),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Text(L.t('Arena', ru: 'Арена'), style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: _SliderTile(
              label: L.t('Sides', ru: 'Стороны'),
              value: '${_draft.sides}',
              min: 3,
              max: 10,
              divisions: 7,
              current: _draft.sides.toDouble(),
              onChanged: (value) =>
                  _update(_draft.copyWith(sides: value.round())),
              hint: L.t(
                'Hexagon is 6. Fewer sides make patterns tighter; more sides leave wider gaps.',
                ru: 'У шестиугольника 6 сторон. Меньше сторон — теснее; больше — шире промежутки.',
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(L.t('Speed & pacing', ru: 'Скорость и темп'),
            style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              children: [
                _SliderTile(
                  label: L.t('Speed multiplier', ru: 'Множитель скорости'),
                  value: _num(_draft.speedMultiplier),
                  min: 0.4,
                  max: 3.0,
                  divisions: 130,
                  current: _draft.speedMultiplier,
                  onChanged: (value) =>
                      _update(_draft.copyWith(speedMultiplier: _round2(value))),
                ),
                _SliderTile(
                  label: L.t('Speed increment', ru: 'Прирост скорости'),
                  value: _num(_draft.speedIncrement),
                  min: 0,
                  max: 0.6,
                  divisions: 60,
                  current: _draft.speedIncrement,
                  onChanged: (value) =>
                      _update(_draft.copyWith(speedIncrement: _round2(value))),
                ),
                _SliderTile(
                  label: L.t('Delay multiplier', ru: 'Множитель задержки'),
                  value: _num(_draft.delayMultiplier),
                  min: 0.5,
                  max: 2.0,
                  divisions: 30,
                  current: _draft.delayMultiplier,
                  onChanged: (value) =>
                      _update(_draft.copyWith(delayMultiplier: _round2(value))),
                ),
                _SliderTile(
                  label: L.t('Delay increment', ru: 'Прирост задержки'),
                  value: _num(_draft.delayIncrement),
                  min: -0.15,
                  max: 0.1,
                  divisions: 25,
                  current: _draft.delayIncrement,
                  onChanged: (value) =>
                      _update(_draft.copyWith(delayIncrement: _round2(value))),
                ),
                _SliderTile(
                  label: L.t('Level-up every', ru: 'Новый уровень каждые'),
                  value: '${_draft.incrementTime.round()}s',
                  min: 3,
                  max: 120,
                  divisions: 39,
                  current: _draft.incrementTime.clamp(3, 120),
                  onChanged: (value) => _update(
                    _draft.copyWith(incrementTime: value.roundToDouble()),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(L.t('Camera rotation', ru: 'Вращение камеры'),
            style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              children: [
                _SliderTile(
                  label: L.t('Rotation speed', ru: 'Скорость вращения'),
                  value: _num(_draft.rotationSpeed),
                  min: 0,
                  max: 0.8,
                  divisions: 80,
                  current: _draft.rotationSpeed,
                  onChanged: (value) =>
                      _update(_draft.copyWith(rotationSpeed: _round2(value))),
                  hint: L.t(
                    'The whole arena turns while you play. Watch it in the preview above.',
                    ru: 'Вся арена вращается во время игры. Это видно в превью выше.',
                  ),
                ),
                _SliderTile(
                  label: L.t('Rotation increment', ru: 'Прирост вращения'),
                  value: _num(_draft.rotationIncrement),
                  min: 0,
                  max: 0.2,
                  divisions: 40,
                  current: _draft.rotationIncrement,
                  onChanged: (value) => _update(
                    _draft.copyWith(rotationIncrement: _round2(value)),
                  ),
                ),
                _SliderTile(
                  label: L.t('Max rotation speed', ru: 'Макс. скорость вращения'),
                  value: _num(_draft.rotationSpeedMax),
                  min: 0.1,
                  max: 1.0,
                  divisions: 18,
                  current: _draft.rotationSpeedMax,
                  onChanged: (value) => _update(
                    _draft.copyWith(rotationSpeedMax: _round2(value)),
                  ),
                ),
                _SliderTile(
                  label: L.t('Fast spin', ru: 'Резкие развороты'),
                  value: _num(_draft.fastSpin),
                  min: 0,
                  max: 1.5,
                  divisions: 30,
                  current: _draft.fastSpin,
                  onChanged: (value) =>
                      _update(_draft.copyWith(fastSpin: _round2(value))),
                  hint: L.t(
                    'Adds sudden camera flips on level-up. Keep it low unless you want chaos.',
                    ru: 'Добавляет резкие перевороты камеры при повышении уровня. Держите значение низким, если не нужен хаос.',
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _patternsTab(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Text(
          L.t(
            'The level loops through this sequence, spawning each pattern at the selected intensity. Reorder the list to change the rhythm.',
            ru: 'Уровень повторяет эту последовательность, запуская каждый паттерн с выбранной интенсивностью. Меняйте порядок, чтобы изменить ритм.',
          ),
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        Card(
          child: SwitchListTile(
            secondary: const Icon(Icons.shuffle),
            title: Text(
              L.t('Shuffle the sequence each cycle', ru: 'Перемешивать последовательность каждый цикл'),
            ),
            subtitle: Text(
              L.t(
                'Guarantees every selected pattern appears before the cycle repeats.',
                ru: 'Гарантирует, что каждый выбранный паттерн появится до повторения цикла.',
              ),
            ),
            value: _draft.shufflePatterns,
            onChanged: (value) =>
                _update(_draft.copyWith(shufflePatterns: value)),
          ),
        ),
        const SizedBox(height: 8),
        if (_draft.patterns.isEmpty)
          Card(
            child: ListTile(
              leading: const Icon(Icons.route_outlined),
              title: Text(L.t('No patterns yet', ru: 'Паттернов пока нет')),
              subtitle: Text(
                L.t(
                  'Add at least one pattern to make a playable level.',
                  ru: 'Добавьте хотя бы один паттерн, чтобы уровень можно было играть.',
                ),
              ),
            ),
          )
        else
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: _draft.patterns.length,
            onReorderItem: _reorderPatterns,
            itemBuilder: (context, index) {
              final pattern = _draft.patterns[index];
              return Card(
                key: ValueKey(pattern.id),
                margin: const EdgeInsets.only(bottom: 8),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(hexPatternIcon(pattern.kind)),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  hexPatternLabel(pattern.kind),
                                  style: theme.textTheme.titleSmall,
                                ),
                                Text(
                                  hexPatternDescription(pattern.kind),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.outline,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: L.t('Remove', ru: 'Удалить'),
                            onPressed: () => _removePattern(pattern),
                            icon: Icon(
                              Icons.delete_outline,
                              color: theme.colorScheme.error,
                            ),
                          ),
                          ReorderableDragStartListener(
                            index: index,
                            child: const Padding(
                              padding: EdgeInsets.all(8),
                              child: Icon(Icons.drag_handle),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      SegmentedButton<int>(
                        segments: [
                          ButtonSegment(
                            value: 1,
                            label: Text(L.t('Calm', ru: 'Спокойно')),
                          ),
                          ButtonSegment(
                            value: 2,
                            label: Text(L.t('Brisk', ru: 'Бодро')),
                          ),
                          ButtonSegment(
                            value: 3,
                            label: Text(L.t('Wild', ru: 'Жёстко')),
                          ),
                        ],
                        selected: {pattern.intensity.clamp(1, 3)},
                        onSelectionChanged: (selection) {
                          _update(
                            _draft.copyWith(
                              patterns: [
                                for (final candidate in _draft.patterns)
                                  candidate.id == pattern.id
                                      ? candidate.copyWith(
                                          intensity: selection.first,
                                        )
                                      : candidate,
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        const SizedBox(height: 4),
        FilledButton.tonalIcon(
          onPressed: _addPattern,
          icon: const Icon(Icons.add),
          label: Text(L.t('Add pattern', ru: 'Добавить паттерн')),
        ),
      ],
    );
  }

  Widget _endingTab(BuildContext context) {
    final theme = Theme.of(context);
    final ending = _draft.ending;
    final minutes = ending.atSeconds ~/ 60;
    final seconds = (ending.atSeconds % 60).toString().padLeft(2, '0');
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Text(
          L.t(
            'The ending is a late-game switch. At the chosen time the level can flip to a generated black-and-white style and boost the speed, so dying in that phase feels like a final stage.',
            ru: 'Концовка — это переключение в конце игры. В выбранный момент уровень может перейти в сгенерированный чёрно-белый стиль и ускориться, чтобы смерть в этой фазе ощущалась как финальная стадия.',
          ),
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        Card(
          child: SwitchListTile(
            secondary: const Icon(Icons.nightlight_outlined),
            title: Text(L.t('Enable ending', ru: 'Включить концовку')),
            subtitle: Text(
              L.t(
                'Adds timed events to the exported level.',
                ru: 'Добавляет в экспортируемый уровень события по времени.',
              ),
            ),
            value: ending.enabled,
            onChanged: (value) => _update(
              _draft.copyWith(ending: ending.copyWith(enabled: value)),
            ),
          ),
        ),
        if (ending.enabled) ...[
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SliderTile(
                    label: L.t('Ending at', ru: 'Концовка на'),
                    value: '$minutes:$seconds',
                    min: 10,
                    max: 300,
                    divisions: 58,
                    current: ending.atSeconds.clamp(10, 300).toDouble(),
                    onChanged: (value) => _update(
                      _draft.copyWith(
                        ending: ending.copyWith(atSeconds: value.round()),
                      ),
                    ),
                  ),
                  TextField(
                    controller: _endingMessage,
                    maxLength: 120,
                    decoration: InputDecoration(
                      labelText: L.t('Ending message', ru: 'Сообщение концовки'),
                      hintText: L.t(
                        'the walls go quiet',
                        ru: 'стены затихают',
                      ),
                      prefixIcon: const Icon(Icons.message_outlined),
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (value) => _update(
                      _draft.copyWith(
                        ending: ending.copyWith(message: value),
                      ),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.contrast),
                    title: Text(
                      L.t('Black & white phase', ru: 'Чёрно-белая фаза'),
                    ),
                    subtitle: Text(
                      L.t(
                        'Switches to a pure monochrome style at the ending time.',
                        ru: 'Переключает на чистый монохромный стиль во время концовки.',
                      ),
                    ),
                    value: ending.blackAndWhite,
                    onChanged: (value) => _update(
                      _draft.copyWith(
                        ending: ending.copyWith(blackAndWhite: value),
                      ),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.speed),
                    title: Text(L.t('Speed boost', ru: 'Ускорение')),
                    subtitle: Text(
                      L.t(
                        'Multiplies speed by 1.18 for the final phase.',
                        ru: 'Умножает скорость на 1.18 в финальной фазе.',
                      ),
                    ),
                    value: ending.speedUp,
                    onChanged: (value) => _update(
                      _draft.copyWith(
                        ending: ending.copyWith(speedUp: value),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            color: theme.colorScheme.secondaryContainer,
            child: ListTile(
              leading: Icon(
                Icons.info_outline,
                color: theme.colorScheme.onSecondaryContainer,
              ),
              title: Text(
                L.t('How the ending is exported', ru: 'Как экспортируется концовка'),
                style: TextStyle(
                  color: theme.colorScheme.onSecondaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                L.t(
                  'The pack gets a second style file and time-based events: style_set, message_important_add and level_float_multiply. The preview shows the B&W phase near the end of its loop.',
                  ru: 'В пак добавляется второй файл стиля и события по времени: style_set, message_important_add и level_float_multiply. Превью показывает чёрно-белую фазу ближе к концу цикла.',
                ),
                style: TextStyle(
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _exportTab(BuildContext context) {
    final theme = Theme.of(context);
    final pack = HexPackBuilder.build(_draft);
    final errors = _errors;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Card(
          color: errors.isEmpty
              ? theme.colorScheme.secondaryContainer
              : theme.colorScheme.errorContainer,
          child: ListTile(
            leading: Icon(
              errors.isEmpty ? Icons.check_circle_outline : Icons.error_outline,
              color: errors.isEmpty
                  ? theme.colorScheme.onSecondaryContainer
                  : theme.colorScheme.onErrorContainer,
            ),
            title: Text(
              errors.isEmpty
                  ? L.t('Ready to export', ru: 'Готово к экспорту')
                  : L.t('Fix these first', ru: 'Сначала исправьте'),
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: errors.isEmpty
                    ? theme.colorScheme.onSecondaryContainer
                    : theme.colorScheme.onErrorContainer,
              ),
            ),
            subtitle: Text(
              errors.isEmpty
                  ? L.t(
                      'The pack has a level, pattern script, style and silent music track.',
                      ru: 'В паке есть уровень, скрипт паттернов, стиль и тихая музыкальная дорожка.',
                    )
                  : errors.map(_localizedError).join('\n'),
              style: TextStyle(
                color: errors.isEmpty
                    ? theme.colorScheme.onSecondaryContainer
                    : theme.colorScheme.onErrorContainer,
              ),
            ),
            isThreeLine: errors.length > 1,
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(L.t('Summary', ru: 'Сводка'), style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                _summaryRow('Pack', _draft.packName),
                _summaryRow('Folder', pack.packFolder, mono: true),
                _summaryRow('Level', _draft.levelName),
                _summaryRow('Level id', pack.levelId, mono: true),
                _summaryRow('Sides', '${_draft.sides}'),
                _summaryRow(
                  'Patterns',
                  '${_draft.patterns.length} · ${_draft.shufflePatterns ? 'shuffled' : 'fixed order'}',
                ),
                _summaryRow(
                  'Ending',
                  _draft.ending.enabled
                      ? '${_draft.ending.atSeconds}s${_draft.ending.blackAndWhite ? ' · B&W' : ''}'
                      : 'off',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: ExpansionTile(
            leading: const Icon(Icons.folder_open_outlined),
            title: Text(L.t('Pack contents', ru: 'Содержимое пака')),
            subtitle: Text(
              L.t(
                '${pack.allPaths.length} files · about ${_kb(pack.totalBytes)} before compression',
                ru: '${pack.allPaths.length} файлов · около ${_kb(pack.totalBytes)} до сжатия',
              ),
            ),
            children: [
              for (final path in pack.allPaths)
                ListTile(
                  dense: true,
                  leading: Icon(
                    path.endsWith('.lua')
                        ? Icons.code
                        : path.endsWith('.ogg')
                            ? Icons.music_note_outlined
                            : Icons.description_outlined,
                    size: 18,
                  ),
                  title: Text(
                    path,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _exporting ? null : _saveZip,
          icon: const Icon(Icons.archive_outlined),
          label: Text(L.t('Save .zip', ru: 'Сохранить .zip')),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _exporting ? null : _exportFolder,
          icon: const Icon(Icons.folder_zip_outlined),
          label: Text(
            L.t('Export as folder', ru: 'Экспортировать папкой'),
          ),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: _showLua,
          icon: const Icon(Icons.code),
          label: Text(
            L.t('View generated Lua', ru: 'Посмотреть сгенерированный Lua'),
          ),
        ),
        const SizedBox(height: 16),
        Text(L.t('Install', ru: 'Установка'), style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Text(
          L.t(
            'Unzip the archive so that the "${pack.packFolder}" folder sits inside Open Hexagon\'s Packs folder, then restart the game. Or choose Export as folder and select your Packs folder directly — the pack is written as Packs/${pack.packFolder}/.',
            ru: 'Распакуйте архив так, чтобы папка "${pack.packFolder}" оказалась внутри папки Packs игры Open Hexagon, затем перезапустите игру. Или выберите «Экспортировать папкой» и укажите папку Packs напрямую — пак будет записан как Packs/${pack.packFolder}/.',
          ),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
        const SizedBox(height: 8),
        Text(
          L.t(
            'The pack targets Open Hexagon 1.92. Music is a bundled silent loop so the level works without another pack; replace the OGG in the exported Music folder to use your own track.',
            ru: 'Пак рассчитан на Open Hexagon 1.92. Музыка — встроенный тихий луп, чтобы уровень работал без других паков; замените OGG в экспортированной папке Music, чтобы использовать свой трек.',
          ),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
      ],
    );
  }

  Widget _summaryRow(String label, String value, {bool mono = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 86,
            child: Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.outline,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontFamily: mono ? 'monospace' : null,
                fontSize: mono ? 12 : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _num(double value) {
    var text = value.toStringAsFixed(2);
    text = text.replaceAll(RegExp(r'0+$'), '');
    if (text.endsWith('.')) text = text.substring(0, text.length - 1);
    return text;
  }

  static double _round2(double value) =>
      (value * 100).roundToDouble() / 100;

  static String _kb(int bytes) {
    if (bytes < 1024) return '$bytes B';
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
}

class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.current,
    required this.onChanged,
    this.hint,
  });

  final String label;
  final String value;
  final double min;
  final double max;
  final int divisions;
  final double current;
  final ValueChanged<double> onChanged;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(label)),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                value,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
        Slider(
          value: current.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
        if (hint != null) ...[
          Text(
            hint!,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 4),
        ],
      ],
    );
  }
}

String hexPatternLabel(HexPatternKind kind) => switch (kind) {
      HexPatternKind.barrage => L.t('Barrage', ru: 'Залп'),
      HexPatternKind.spiral => L.t('Spiral', ru: 'Спираль'),
      HexPatternKind.alternate => L.t('Alternate', ru: 'Переменка'),
      HexPatternKind.tunnel => L.t('Tunnel', ru: 'Тоннель'),
      HexPatternKind.zipper => L.t('Zipper', ru: 'Зигзаг'),
      HexPatternKind.mirror => L.t('Mirror', ru: 'Зеркало'),
      HexPatternKind.sweep => L.t('Sweep', ru: 'Развёртка'),
      HexPatternKind.breather => L.t('Breather', ru: 'Передышка'),
    };

String hexPatternDescription(HexPatternKind kind) => switch (kind) {
      HexPatternKind.barrage => L.t(
          'A burst of walls on one side. Move early and commit.',
          ru: 'Серия стен с одной стороны. Двигайтесь заранее и не сомневайтесь.',
        ),
      HexPatternKind.spiral => L.t(
          'Single walls rotate around the arena like a clock hand.',
          ru: 'Одиночные стены идут по кругу, как стрелка часов.',
        ),
      HexPatternKind.alternate => L.t(
          'Opposite walls trade places, forcing quick lane changes.',
          ru: 'Противоположные стены меняются местами, заставляя быстро менять полосу.',
        ),
      HexPatternKind.tunnel => L.t(
          'A wide pincer from both sides with a generous approach.',
          ru: 'Широкие клещи с двух сторон с запасом на реакцию.',
        ),
      HexPatternKind.zipper => L.t(
          'Tight zig-zag walls that punish late direction changes.',
          ru: 'Плотный зигзаг, наказывающий за позднюю смену направления.',
        ),
      HexPatternKind.mirror => L.t(
          'Paired walls step around the arena while staying opposite.',
          ru: 'Парные стены шагают по арене, оставаясь напротив друг друга.',
        ),
      HexPatternKind.sweep => L.t(
          'A full sweep around the arena with one moving safe gap.',
          ru: 'Полный проход по арене с одним движущимся безопасным промежутком.',
        ),
      HexPatternKind.breather => L.t(
          'No walls, just a short rest between harder patterns.',
          ru: 'Без стен — короткая передышка между сложными паттернами.',
        ),
    };

IconData hexPatternIcon(HexPatternKind kind) => switch (kind) {
      HexPatternKind.barrage => Icons.align_horizontal_left,
      HexPatternKind.spiral => Icons.rotate_right,
      HexPatternKind.alternate => Icons.swap_horiz,
      HexPatternKind.tunnel => Icons.compress,
      HexPatternKind.zipper => Icons.timeline,
      HexPatternKind.mirror => Icons.flip,
      HexPatternKind.sweep => Icons.threesixty,
      HexPatternKind.breather => Icons.hourglass_empty,
    };

String hexPaletteLabel(HexPalette palette) => switch (palette) {
      HexPalette.neon => L.t('Neon', ru: 'Неон'),
      HexPalette.ember => L.t('Ember', ru: 'Угли'),
      HexPalette.ocean => L.t('Ocean', ru: 'Океан'),
      HexPalette.mono => L.t('Mono', ru: 'Моно'),
    };
