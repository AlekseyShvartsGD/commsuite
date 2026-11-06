/// Data model for the Open Hexagon 1.92 map maker.
///
/// The model is intentionally self-contained and free of Flutter imports so
/// pack generation can be unit-tested with plain Dart.
library;

/// Pattern families the map maker can arrange into a level timeline.
enum HexPatternKind {
  barrage,
  spiral,
  alternate,
  tunnel,
  zipper,
  mirror,
  sweep,
  breather,
}

/// Visual palette used for the generated style file.
enum HexPalette { neon, ember, ocean, mono }

HexPatternKind? hexPatternFromId(String? id) {
  for (final kind in HexPatternKind.values) {
    if (kind.name == id) return kind;
  }
  return null;
}

/// Makes a filesystem- and id-safe token out of free text.
///
/// Open Hexagon ids end up in file names, JSON ids and score keys, so keep
/// them lower-case ASCII with underscores only.
String hexSlugify(String raw, {required String fallback}) {
  var value = raw.toLowerCase().trim();
  value = value.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
  value = value.replaceAll(RegExp(r'_+'), '_');
  value = value.replaceAll(RegExp(r'^_|_$'), '');
  if (value.isEmpty) return fallback;
  if (RegExp(r'^[0-9]').hasMatch(value)) value = 'level_$value';
  return value.length > 48 ? value.substring(0, 48) : value;
}

int _patternIdCounter = 0;

/// One entry in the level's repeating pattern sequence.
class HexPatternSelection {
  HexPatternSelection({
    required this.kind,
    this.intensity = 2,
    String? id,
  }) : id = id ?? 'p${DateTime.now().microsecondsSinceEpoch}_${_patternIdCounter++}';

  /// Stable identity for reorderable lists and drafts.
  final String id;
  final HexPatternKind kind;

  /// 1 = calm, 2 = brisk, 3 = wild.
  final int intensity;

  HexPatternSelection copyWith({HexPatternKind? kind, int? intensity}) {
    return HexPatternSelection(
      id: id,
      kind: kind ?? this.kind,
      intensity: intensity ?? this.intensity,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'intensity': intensity,
      };

  factory HexPatternSelection.fromJson(Map<String, dynamic> json) {
    return HexPatternSelection(
      id: json['id'] is String ? json['id'] as String : null,
      kind: hexPatternFromId(json['kind'] as String?) ?? HexPatternKind.barrage,
      intensity: (json['intensity'] as num?)?.toInt() ?? 2,
    );
  }
}

/// Optional late-game style switch. This is how the map maker produces the
/// "death in a black and white stage" ending: a generated monochrome style is
/// activated partway through the level.
class HexEnding {
  const HexEnding({
    this.enabled = false,
    this.atSeconds = 60,
    this.message = 'the walls go quiet',
    this.blackAndWhite = true,
    this.speedUp = true,
  });

  final bool enabled;
  final int atSeconds;
  final String message;
  final bool blackAndWhite;
  final bool speedUp;

  HexEnding copyWith({
    bool? enabled,
    int? atSeconds,
    String? message,
    bool? blackAndWhite,
    bool? speedUp,
  }) {
    return HexEnding(
      enabled: enabled ?? this.enabled,
      atSeconds: atSeconds ?? this.atSeconds,
      message: message ?? this.message,
      blackAndWhite: blackAndWhite ?? this.blackAndWhite,
      speedUp: speedUp ?? this.speedUp,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'atSeconds': atSeconds,
        'message': message,
        'blackAndWhite': blackAndWhite,
        'speedUp': speedUp,
      };

  factory HexEnding.fromJson(Map<String, dynamic> json) {
    return HexEnding(
      enabled: json['enabled'] as bool? ?? false,
      atSeconds: (json['atSeconds'] as num?)?.toInt() ?? 60,
      message: json['message'] as String? ?? 'the walls go quiet',
      blackAndWhite: json['blackAndWhite'] as bool? ?? true,
      speedUp: json['speedUp'] as bool? ?? true,
    );
  }
}

/// Everything needed to generate one Open Hexagon pack with one level.
class HexMapDraft {
  HexMapDraft({
    required this.packName,
    required this.levelName,
    required this.author,
    required this.description,
    required this.menuPriority,
    required this.palette,
    required this.sides,
    required this.speedMultiplier,
    required this.speedIncrement,
    required this.rotationSpeed,
    required this.rotationIncrement,
    required this.delayMultiplier,
    required this.delayIncrement,
    required this.incrementTime,
    required this.rotationSpeedMax,
    required this.fastSpin,
    required this.patterns,
    required this.shufflePatterns,
    required this.ending,
  });

  factory HexMapDraft.defaults({String author = ''}) {
    return HexMapDraft(
      packName: 'My Hexagon Pack',
      levelName: 'First Orbit',
      author: author,
      description: 'A custom Open Hexagon level made with Commsuite',
      menuPriority: 10,
      palette: HexPalette.neon,
      sides: 6,
      speedMultiplier: 1.84,
      speedIncrement: 0.18,
      rotationSpeed: 0.13,
      rotationIncrement: 0.04,
      delayMultiplier: 1.0,
      delayIncrement: -0.03,
      incrementTime: 15,
      rotationSpeedMax: 0.4,
      fastSpin: 0.0,
      patterns: [
        HexPatternSelection(kind: HexPatternKind.barrage, intensity: 2),
        HexPatternSelection(kind: HexPatternKind.spiral, intensity: 2),
        HexPatternSelection(kind: HexPatternKind.alternate, intensity: 2),
        HexPatternSelection(kind: HexPatternKind.tunnel, intensity: 2),
        HexPatternSelection(kind: HexPatternKind.zipper, intensity: 2),
      ],
      shufflePatterns: true,
      ending: const HexEnding(),
    );
  }

  final String packName;
  final String levelName;
  final String author;
  final String description;
  final int menuPriority;
  final HexPalette palette;
  final int sides;
  final double speedMultiplier;
  final double speedIncrement;
  final double rotationSpeed;
  final double rotationIncrement;
  final double delayMultiplier;
  final double delayIncrement;
  final double incrementTime;
  final double rotationSpeedMax;

  /// Chance/speed of abrupt 180-degree spins on level up.
  final double fastSpin;
  final List<HexPatternSelection> patterns;
  final bool shufflePatterns;
  final HexEnding ending;

  /// Folder name / pack id. Open Hexagon uses the folder name as the pack id.
  String get packSlug => hexSlugify(packName, fallback: 'commsuite_pack');

  /// Level id, also used as the base id for the generated style and music.
  String get levelSlug => hexSlugify(levelName, fallback: 'custom_level');

  String get styleId => '${levelSlug}_style';

  String get endingStyleId => '${levelSlug}_bw';

  String get musicId => '${levelSlug}_theme';

  String get musicFileName => '${levelSlug}_theme.ogg';

  HexMapDraft copyWith({
    String? packName,
    String? levelName,
    String? author,
    String? description,
    int? menuPriority,
    HexPalette? palette,
    int? sides,
    double? speedMultiplier,
    double? speedIncrement,
    double? rotationSpeed,
    double? rotationIncrement,
    double? delayMultiplier,
    double? delayIncrement,
    double? incrementTime,
    double? rotationSpeedMax,
    double? fastSpin,
    List<HexPatternSelection>? patterns,
    bool? shufflePatterns,
    HexEnding? ending,
  }) {
    return HexMapDraft(
      packName: packName ?? this.packName,
      levelName: levelName ?? this.levelName,
      author: author ?? this.author,
      description: description ?? this.description,
      menuPriority: menuPriority ?? this.menuPriority,
      palette: palette ?? this.palette,
      sides: sides ?? this.sides,
      speedMultiplier: speedMultiplier ?? this.speedMultiplier,
      speedIncrement: speedIncrement ?? this.speedIncrement,
      rotationSpeed: rotationSpeed ?? this.rotationSpeed,
      rotationIncrement: rotationIncrement ?? this.rotationIncrement,
      delayMultiplier: delayMultiplier ?? this.delayMultiplier,
      delayIncrement: delayIncrement ?? this.delayIncrement,
      incrementTime: incrementTime ?? this.incrementTime,
      rotationSpeedMax: rotationSpeedMax ?? this.rotationSpeedMax,
      fastSpin: fastSpin ?? this.fastSpin,
      patterns: patterns ?? this.patterns,
      shufflePatterns: shufflePatterns ?? this.shufflePatterns,
      ending: ending ?? this.ending,
    );
  }

  /// User-facing problems that block export. Empty means the draft is valid.
  List<String> validate() {
    final errors = <String>[];
    if (packName.trim().isEmpty) {
      errors.add('Pack name is required.');
    }
    if (levelName.trim().isEmpty) {
      errors.add('Level name is required.');
    }
    if (author.trim().isEmpty) {
      errors.add('Author is required.');
    }
    if (description.trim().length > 300) {
      errors.add('Description must be 300 characters or fewer.');
    }
    if (sides < 3 || sides > 10) {
      errors.add('Sides must be between 3 and 10.');
    }
    if (speedMultiplier < 0.4 || speedMultiplier > 4.0) {
      errors.add('Speed multiplier must be between 0.4 and 4.0.');
    }
    if (incrementTime < 3 || incrementTime > 180) {
      errors.add('Increment time must be between 3 and 180 seconds.');
    }
    if (patterns.isEmpty) {
      errors.add('Add at least one pattern to the sequence.');
    }
    if (ending.enabled) {
      if (ending.atSeconds < 5 || ending.atSeconds > 3600) {
        errors.add('Ending time must be between 5 and 3600 seconds.');
      }
      if (ending.message.trim().length > 120) {
        errors.add('Ending message must be 120 characters or fewer.');
      }
      if (!ending.blackAndWhite && !ending.speedUp &&
          ending.message.trim().isEmpty) {
        errors.add('Enable at least one ending effect.');
      }
    }
    return errors;
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'packName': packName,
        'levelName': levelName,
        'author': author,
        'description': description,
        'menuPriority': menuPriority,
        'palette': palette.name,
        'sides': sides,
        'speedMultiplier': speedMultiplier,
        'speedIncrement': speedIncrement,
        'rotationSpeed': rotationSpeed,
        'rotationIncrement': rotationIncrement,
        'delayMultiplier': delayMultiplier,
        'delayIncrement': delayIncrement,
        'incrementTime': incrementTime,
        'rotationSpeedMax': rotationSpeedMax,
        'fastSpin': fastSpin,
        'patterns': [for (final pattern in patterns) pattern.toJson()],
        'shufflePatterns': shufflePatterns,
        'ending': ending.toJson(),
      };

  factory HexMapDraft.fromJson(Map<String, dynamic> json) {
    final paletteName = json['palette'] as String?;
    final palette = HexPalette.values.firstWhere(
      (value) => value.name == paletteName,
      orElse: () => HexPalette.neon,
    );
    final rawPatterns = json['patterns'];
    List<HexPatternSelection>? parsedPatterns;
    if (rawPatterns is List) {
      parsedPatterns = <HexPatternSelection>[];
      for (final entry in rawPatterns) {
        if (entry is Map) {
          parsedPatterns.add(
            HexPatternSelection.fromJson(Map<String, dynamic>.from(entry)),
          );
        }
      }
    }
    final fallback = HexMapDraft.defaults();
    return HexMapDraft(
      packName: json['packName'] as String? ?? fallback.packName,
      levelName: json['levelName'] as String? ?? fallback.levelName,
      author: json['author'] as String? ?? fallback.author,
      description: json['description'] as String? ?? fallback.description,
      menuPriority: (json['menuPriority'] as num?)?.toInt() ??
          fallback.menuPriority,
      palette: palette,
      sides: (json['sides'] as num?)?.toInt() ?? fallback.sides,
      speedMultiplier: (json['speedMultiplier'] as num?)?.toDouble() ??
          fallback.speedMultiplier,
      speedIncrement: (json['speedIncrement'] as num?)?.toDouble() ??
          fallback.speedIncrement,
      rotationSpeed: (json['rotationSpeed'] as num?)?.toDouble() ??
          fallback.rotationSpeed,
      rotationIncrement: (json['rotationIncrement'] as num?)?.toDouble() ??
          fallback.rotationIncrement,
      delayMultiplier: (json['delayMultiplier'] as num?)?.toDouble() ??
          fallback.delayMultiplier,
      delayIncrement: (json['delayIncrement'] as num?)?.toDouble() ??
          fallback.delayIncrement,
      incrementTime: (json['incrementTime'] as num?)?.toDouble() ??
          fallback.incrementTime,
      rotationSpeedMax: (json['rotationSpeedMax'] as num?)?.toDouble() ??
          fallback.rotationSpeedMax,
      fastSpin: (json['fastSpin'] as num?)?.toDouble() ?? fallback.fastSpin,
      patterns: parsedPatterns ?? fallback.patterns,
      shufflePatterns: json['shufflePatterns'] as bool? ??
          fallback.shufflePatterns,
      ending: json['ending'] is Map
          ? HexEnding.fromJson(
              Map<String, dynamic>.from(json['ending'] as Map),
            )
          : fallback.ending,
    );
  }
}
