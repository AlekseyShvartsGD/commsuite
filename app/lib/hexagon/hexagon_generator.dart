/// Generates a self-contained Open Hexagon 1.92 pack from a [HexMapDraft].
///
/// The output is plain JSON/Lua text; the exporter adds the bundled silent
/// OGG so the pack does not depend on another pack's music.
library;

import 'dart:convert';

import 'hexagon_models.dart';

class GeneratedHexPack {
  const GeneratedHexPack({
    required this.packFolder,
    required this.levelId,
    required this.textFiles,
    required this.audioFiles,
  });

  /// Folder to place inside `Packs/`.
  final String packFolder;
  final String levelId;

  /// Relative path inside the pack folder -> UTF-8 text contents.
  final Map<String, String> textFiles;

  /// Relative path inside the pack folder -> bundled asset path.
  final Map<String, String> audioFiles;

  List<String> get allPaths => [
        ...textFiles.keys,
        ...audioFiles.keys,
      ]..sort();

  int get totalBytes => textFiles.values.fold<int>(
        0,
        (sum, text) => sum + utf8.encode(text).length,
      );
}

class HexPackBuilder {
  HexPackBuilder._();

  static const String silenceAsset = 'assets/hexagon/silence.ogg';

  static GeneratedHexPack build(HexMapDraft draft) {
    final levelId = draft.levelSlug;
    final styleFiles = <String, String>{
      'Styles/${draft.styleId}.json': _encode(
        _styleJson(id: draft.styleId, palette: draft.palette),
      ),
    };
    if (draft.ending.enabled && draft.ending.blackAndWhite) {
      styleFiles['Styles/${draft.endingStyleId}.json'] = _encode(
        _styleJson(
          id: draft.endingStyleId,
          palette: HexPalette.mono,
          pureMonochrome: true,
        ),
      );
    }

    final textFiles = <String, String>{
      'pack.json': _encode({
        'name': draft.packName.trim(),
        'priority': draft.menuPriority,
      }),
      'Levels/$levelId.json': _encode(_levelJson(draft)),
      'Scripts/$levelId.lua': _luaScript(draft),
      'Music/${draft.musicId}.json': _encode({
        'id': draft.musicId,
        'file_name': draft.musicFileName,
        'name': 'Silence',
        'album': 'Commsuite Map Maker',
        'author': 'Commsuite',
        'segments': [
          {'time': 0},
        ],
      }),
      ...styleFiles,
      'README.txt': _readme(draft),
    };

    return GeneratedHexPack(
      packFolder: draft.packSlug,
      levelId: levelId,
      textFiles: textFiles,
      audioFiles: {
        'Music/${draft.musicFileName}': silenceAsset,
      },
    );
  }

  static String _encode(Object value) =>
      const JsonEncoder.withIndent('  ').convert(value);

  static Map<String, dynamic> _levelJson(HexMapDraft draft) {
    final levelId = draft.levelSlug;
    final events = <Map<String, dynamic>>[];
    if (draft.ending.enabled) {
      final ending = draft.ending;
      final time = ending.atSeconds;
      final message = ending.message.trim();
      if (ending.blackAndWhite) {
        events.add({
          'time': time,
          'type': 'style_set',
          'id': draft.endingStyleId,
        });
      }
      if (message.isNotEmpty) {
        events.add({
          'time': time,
          'type': 'message_important_add',
          'duration': 200,
          'message': message,
        });
      }
      if (ending.speedUp) {
        events.add({
          'time': time,
          'type': 'level_float_multiply',
          'value_name': 'speed_multiplier',
          'value': 1.18,
        });
      }
    }

    return {
      'id': levelId,
      'name': draft.levelName.trim(),
      'description': draft.description.trim(),
      'author': draft.author.trim(),
      'menu_priority': draft.menuPriority,
      'selectable': true,
      'style_id': draft.styleId,
      'music_id': draft.musicId,
      'lua_file': '$levelId.lua',
      'difficulty_multipliers': <double>[1.0],

      // Gameplay
      'speed_multiplier': draft.speedMultiplier,
      'speed_increment': draft.speedIncrement,
      'rotation_speed': draft.rotationSpeed,
      'rotation_increment': draft.rotationIncrement,
      'delay_multiplier': draft.delayMultiplier,
      'delay_increment': draft.delayIncrement,
      'fast_spin': draft.fastSpin,
      'sides': draft.sides,
      'sides_min': draft.sides,
      'sides_max': draft.sides,
      'increment_time': draft.incrementTime,
      'rotation_speed_max': draft.rotationSpeedMax,

      // Cosmetic pulse values keep the default level's feel.
      'pulse_min': 75.0,
      'pulse_max': 91.0,
      'pulse_speed': 1.5,
      'pulse_speed_r': 0.6,
      'pulse_delay_max': 9.1,
      'beatpulse_max': 17.0,
      'beatpulse_delay_max': 23.8,

      'events': events,
    };
  }

  static Map<String, dynamic> _styleJson({
    required String id,
    required HexPalette palette,
    bool pureMonochrome = false,
  }) {
    if (pureMonochrome) {
      return {
        'id': id,
        'hue_min': 0,
        'hue_max': 0,
        'hue_ping_pong': false,
        'hue_increment': 0.0,
        'pulse_min': 0.0,
        'pulse_max': 1.2,
        'pulse_increment': 0.02,
        '3D_depth': 8,
        '3D_skew': 0.18,
        '3D_spacing': 1.4,
        '3D_darken_multiplier': 1.4,
        '3D_alpha_multiplier': 0.35,
        '3D_alpha_falloff': 1.2,
        '3D_override_color': [235, 235, 235, 255],
        'main': {
          'main': true,
          'dynamic': false,
          'value': [255, 255, 255, 255],
          'pulse': [0, 0, 0, 0],
        },
        'colors': [
          {
            'dynamic': false,
            'dynamic_offset': false,
            'dynamic_darkness': 1.0,
            'value': [0, 0, 0, 255],
            'pulse': [0, 0, 0, 0],
          },
          {
            'dynamic': false,
            'dynamic_offset': false,
            'dynamic_darkness': 1.0,
            'value': [16, 16, 16, 255],
            'pulse': [0, 0, 0, 0],
          },
        ],
      };
    }

    final config = switch (palette) {
      HexPalette.neon => (
          hueMin: 155,
          hueMax: 320,
          pingPong: true,
          hueIncrement: 0.85,
          pulseMax: 2.0,
          depth: 8,
          spacing: 1.3,
          firstValue: <int>[0, 0, 0, 0],
          firstDarkness: 2.7,
          secondValue: <int>[20, 35, 30, 255],
          secondOffset: true,
          secondDarkness: 2.3,
        ),
      HexPalette.ember => (
          hueMin: 0,
          hueMax: 55,
          pingPong: true,
          hueIncrement: 0.42,
          pulseMax: 1.8,
          depth: 10,
          spacing: 1.7,
          firstValue: <int>[0, 0, 0, 0],
          firstDarkness: 2.5,
          secondValue: <int>[38, 14, 6, 255],
          secondOffset: false,
          secondDarkness: 3.1,
        ),
      HexPalette.ocean => (
          hueMin: 175,
          hueMax: 255,
          pingPong: false,
          hueIncrement: 0.5,
          pulseMax: 1.6,
          depth: 11,
          spacing: 1.5,
          firstValue: <int>[0, 0, 0, 0],
          firstDarkness: 2.4,
          secondValue: <int>[8, 22, 40, 255],
          secondOffset: true,
          secondDarkness: 2.6,
        ),
      HexPalette.mono => (
          hueMin: 0,
          hueMax: 0,
          pingPong: false,
          hueIncrement: 0.0,
          pulseMax: 1.5,
          depth: 9,
          spacing: 1.4,
          firstValue: <int>[30, 30, 30, 255],
          firstDarkness: 1.0,
          secondValue: <int>[8, 8, 8, 255],
          secondOffset: false,
          secondDarkness: 1.0,
        ),
    };

    final dynamicColors =
        palette != HexPalette.mono && palette != HexPalette.neon;
    return {
      'id': id,
      'hue_min': config.hueMin,
      'hue_max': config.hueMax,
      'hue_ping_pong': config.pingPong,
      'hue_increment': config.hueIncrement,
      'pulse_min': 0.0,
      'pulse_max': config.pulseMax,
      'pulse_increment': 0.025,
      '3D_depth': config.depth,
      '3D_skew': 0.16,
      '3D_spacing': config.spacing,
      '3D_darken_multiplier': 1.2,
      '3D_alpha_multiplier': 0.4,
      '3D_alpha_falloff': 1.0,
      '3D_override_color': [166, 166, 166, 255],
      'main': {
        'main': true,
        'dynamic': false,
        'value': [253, 253, 253, 255],
        'pulse': [0, 0, 0, 0],
      },
      'colors': [
        {
          'dynamic': dynamicColors || palette == HexPalette.neon,
          'dynamic_offset': false,
          'dynamic_darkness': config.firstDarkness,
          'value': config.firstValue,
          'pulse': [0, 0, 0, 0],
        },
        {
          'dynamic': dynamicColors,
          'dynamic_offset': config.secondOffset,
          'dynamic_darkness': config.secondDarkness,
          'value': config.secondValue,
          'pulse': [0, 0, 0, 0],
        },
      ],
    };
  }

  static String _luaScript(HexMapDraft draft) {
    final sequence = draft.patterns
        .map((pattern) => '"${pattern.kind.name}"')
        .join(', ');
    final intensity =
        draft.patterns.map((pattern) => pattern.intensity.clamp(1, 3)).join(', ');

    return '''-- Generated by the Commsuite Open Hexagon map maker.
-- Original pattern code; safe to edit once you know Lua.

local THICKNESS = 40.0
local sequence = { $sequence }
local intensity = { $intensity }
local shufflePatterns = ${draft.shufflePatterns ? 'true' : 'false'}

local function perfectDelay(thickness)
  return thickness / (5.02 * getSpeedMult()) * getDelayMult()
end

local function anySide()
  return math.random(0, getSides() - 1)
end

local function randomDirection()
  if math.random(0, 1) == 0 then return -1 end
  return 1
end

local function oppositeOf(side)
  return side + math.floor(getSides() / 2)
end

local function settle()
  wait(perfectDelay(THICKNESS) * 4.0)
end

-- A burst of walls on one side: the player must move clear and stay clear.
local function patternBarrage(level)
  local thickness = THICKNESS * (1.0 + 0.12 * (level - 1))
  local side = anySide()
  local count = 3 + level
  for i = 1, count do
    wall(side, thickness)
    wait(perfectDelay(thickness) * (0.85 + 0.1 * (level - 1)))
  end
  settle()
end

-- A rotating spiral of single walls.
local function patternSpiral(level)
  local side = anySide()
  local direction = randomDirection()
  local count = 4 + level
  for i = 1, count do
    wall(side, THICKNESS)
    side = side + direction
    wait(perfectDelay(THICKNESS) * (1.2 - 0.05 * (level - 1)))
  end
  settle()
end

-- Alternating opposite walls leave two safe lanes that swap every beat.
local function patternAlternate(level)
  local side = anySide()
  local opposite = oppositeOf(side)
  local count = 3 + level
  for i = 1, count do
    wall(side, THICKNESS)
    wait(perfectDelay(THICKNESS) * (3.5 - 0.2 * (level - 1)))
    wall(opposite, THICKNESS)
    wait(perfectDelay(THICKNESS) * (3.5 - 0.2 * (level - 1)))
  end
  settle()
end

-- A wide pincer: two opposite walls arrive together.
local function patternTunnel(level)
  local side = anySide()
  local thickness = THICKNESS * (1.0 + 0.08 * level)
  wall(side, thickness)
  wall(oppositeOf(side), thickness)
  wait(perfectDelay(thickness) * (4.5 + level * 0.5))
end

-- A tight zig-zag: a pair of adjacent walls steps around the arena.
local function patternZipper(level)
  local side = anySide()
  local direction = randomDirection()
  local count = 4 + level
  for i = 1, count do
    wall(side, THICKNESS)
    wall(side + direction, THICKNESS * 0.8)
    side = side + direction
    wait(perfectDelay(THICKNESS) * (1.35 - 0.05 * (level - 1)))
  end
  settle()
end

-- Pairs of opposite walls that step around the arena.
local function patternMirror(level)
  local side = anySide()
  local opposite = oppositeOf(side)
  local count = 2 + level
  for i = 1, count do
    wall(side, THICKNESS)
    wall(opposite, THICKNESS)
    side = side + 1
    opposite = opposite - 1
    wait(perfectDelay(THICKNESS) * (1.4 - 0.08 * (level - 1)))
  end
  settle()
end

-- A sweep around every side, leaving one moving safe gap.
local function patternSweep(level)
  local side = anySide()
  local direction = randomDirection()
  local count = getSides() - 1
  for i = 1, count do
    wall(side, THICKNESS)
    side = side + direction
    wait(perfectDelay(THICKNESS) * (1.2 - 0.05 * (level - 1)))
  end
  settle()
end

-- A short rest so long sequences breathe.
local function patternBreather(level)
  wait(perfectDelay(THICKNESS) * (3.0 + level))
end

local dispatchers = {
  barrage = patternBarrage,
  spiral = patternSpiral,
  alternate = patternAlternate,
  tunnel = patternTunnel,
  zipper = patternZipper,
  mirror = patternMirror,
  sweep = patternSweep,
  breather = patternBreather,
}

local count = #sequence
local order = {}
local cursor = 0

local function refill()
  for i = 1, count do order[i] = i end
  if shufflePatterns then
    for i = count, 2, -1 do
      local j = math.random(1, i)
      order[i], order[j] = order[j], order[i]
    end
  end
  cursor = 0
end

function onLoad()
  refill()
end

function onStep()
  if count == 0 then
    wait(60)
    return
  end

  cursor = cursor + 1
  if cursor > count then
    refill()
    cursor = 1
  end

  local index = order[cursor]
  local dispatcher = dispatchers[sequence[index]]
  if dispatcher == nil then
    wait(60)
  else
    dispatcher(intensity[index])
  end
end

function onIncrement()
end

function onUnload()
end

function onUpdate(mFrameTime)
end
''';
  }

  static String _readme(HexMapDraft draft) {
    final pack = draft.packSlug;
    return '''${draft.levelName.trim()} - Open Hexagon 1.92 pack
Generated with the Commsuite map maker.

INSTALL
1. Copy the "$pack" folder into your Open Hexagon "Packs" folder.
2. Start Open Hexagon and pick "${draft.levelName.trim()}" from the level menu.

The pack is self-contained: it includes its style, patterns and a silent
music track. Replace Music/${draft.musicFileName} with any OGG and update
Music/${draft.musicId}.json if you want real music.

PATTERNS
${draft.patterns.map((pattern) => '- ${pattern.kind.name} (intensity ${pattern.intensity})').join('\n')}

ENDING
${draft.ending.enabled ? 'Enabled at ${draft.ending.atSeconds}s${draft.ending.blackAndWhite ? ', black and white style' : ''}${draft.ending.speedUp ? ', speed boost' : ''}.' : 'Disabled.'}

You can edit Levels/${draft.levelSlug}.json and Scripts/${draft.levelSlug}.lua
after exporting; plain JSON and Lua are welcome here.
''';
  }
}
