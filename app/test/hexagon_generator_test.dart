import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:commsuite/hexagon/hexagon_exporter.dart';
import 'package:commsuite/hexagon/hexagon_generator.dart';
import 'package:commsuite/hexagon/hexagon_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  HexMapDraft draft({
    bool ending = false,
    bool blackAndWhite = true,
    bool speedUp = true,
    String message = 'the walls go quiet',
  }) {
    final base = HexMapDraft.defaults(author: 'Aleksey');
    return base.copyWith(
      ending: HexEnding(
        enabled: ending,
        atSeconds: 90,
        message: message,
        blackAndWhite: blackAndWhite,
        speedUp: speedUp,
      ),
    );
  }

  group('HexMapDraft', () {
    test('slugifies ids into safe pack, level and asset names', () {
      final value = draft().copyWith(
        packName: '  My Pack!!  ',
        levelName: 'Level 42: The End',
      );

      expect(value.packSlug, 'my_pack');
      expect(value.levelSlug, 'level_42_the_end');
      expect(value.styleId, 'level_42_the_end_style');
      expect(value.endingStyleId, 'level_42_the_end_bw');
      expect(value.musicId, 'level_42_the_end_theme');
      expect(value.musicFileName, 'level_42_the_end_theme.ogg');
    });

    test('falls back when a name has no usable characters', () {
      final value = draft().copyWith(packName: '!!!', levelName: '☃');
      expect(value.packSlug, 'commsuite_pack');
      expect(value.levelSlug, 'custom_level');
    });

    test('reports actionable validation errors', () {
      final invalid = draft().copyWith(
        packName: ' ',
        levelName: '',
        author: '',
        sides: 2,
        speedMultiplier: 9,
        incrementTime: 1,
        patterns: const [],
      );

      final errors = invalid.validate();
      expect(errors, contains('Pack name is required.'));
      expect(errors, contains('Level name is required.'));
      expect(errors, contains('Author is required.'));
      expect(errors, contains('Sides must be between 3 and 10.'));
      expect(
        errors,
        contains('Speed multiplier must be between 0.4 and 4.0.'),
      );
      expect(
        errors,
        contains('Increment time must be between 3 and 180 seconds.'),
      );
      expect(errors, contains('Add at least one pattern to the sequence.'));
    });

    test('accepts a default draft with an author', () {
      expect(draft().validate(), isEmpty);
      expect(draft().description.endsWith('.'), isFalse);
    });

    test('round-trips through JSON including camera settings', () {
      final original = draft(ending: true).copyWith(
        fastSpin: 0.45,
        rotationSpeed: 0.37,
        rotationIncrement: 0.08,
        rotationSpeedMax: 0.91,
        palette: HexPalette.ocean,
      );

      final restored = HexMapDraft.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );

      expect(restored.packName, original.packName);
      expect(restored.fastSpin, original.fastSpin);
      expect(restored.rotationSpeed, original.rotationSpeed);
      expect(restored.rotationIncrement, original.rotationIncrement);
      expect(restored.rotationSpeedMax, original.rotationSpeedMax);
      expect(restored.palette, HexPalette.ocean);
      expect(restored.patterns.length, original.patterns.length);
      expect(restored.patterns.first.kind, original.patterns.first.kind);
      expect(restored.ending.enabled, isTrue);
      expect(restored.ending.atSeconds, 90);
    });

    test('keeps an intentionally empty pattern sequence', () {
      final empty = draft().copyWith(patterns: const []);
      final restored = HexMapDraft.fromJson(empty.toJson());

      expect(restored.patterns, isEmpty);
    });
  });

  group('HexPackBuilder', () {
    test('emits every file Open Hexagon 1.92 needs', () {
      final pack = HexPackBuilder.build(draft());
      final paths = pack.allPaths;

      expect(paths, contains('pack.json'));
      expect(paths, contains('Levels/first_orbit.json'));
      expect(paths, contains('Scripts/first_orbit.lua'));
      expect(paths, contains('Styles/first_orbit_style.json'));
      expect(paths, contains('Music/first_orbit_theme.json'));
      expect(paths, contains('Music/first_orbit_theme.ogg'));
      expect(paths, contains('README.txt'));
      expect(pack.packFolder, 'my_hexagon_pack');
      expect(pack.levelId, 'first_orbit');
    });

    test('writes a level that points at its own assets', () {
      final pack = HexPackBuilder.build(draft());
      final level = jsonDecode(
        pack.textFiles['Levels/first_orbit.json']!,
      ) as Map<String, dynamic>;

      expect(level['id'], 'first_orbit');
      expect(level['style_id'], 'first_orbit_style');
      expect(level['music_id'], 'first_orbit_theme');
      expect(level['lua_file'], 'first_orbit.lua');
      expect(level['sides'], 6);
      expect(level['sides_min'], 6);
      expect(level['sides_max'], 6);
      expect(level['fast_spin'], 0.0);
      expect(level['events'], isEmpty);
      expect(level['difficulty_multipliers'], [1.0]);
    });

    test('adds black-and-white ending events and a matching style', () {
      final pack = HexPackBuilder.build(draft(ending: true));
      final level = jsonDecode(
        pack.textFiles['Levels/first_orbit.json']!,
      ) as Map<String, dynamic>;
      final events = (level['events'] as List).cast<Map<String, dynamic>>();

      expect(pack.textFiles, contains('Styles/first_orbit_bw.json'));
      expect(
        events.map((event) => event['type']),
        containsAll([
          'style_set',
          'message_important_add',
          'level_float_multiply',
        ]),
      );
      expect(
        events.every((event) => event['time'] == 90),
        isTrue,
      );
      final styleSet = events.firstWhere(
        (event) => event['type'] == 'style_set',
      );
      expect(styleSet['id'], 'first_orbit_bw');
      final boost = events.firstWhere(
        (event) => event['type'] == 'level_float_multiply',
      );
      expect(boost['value_name'], 'speed_multiplier');
      expect(boost['value'], 1.18);

      final bw = jsonDecode(
        pack.textFiles['Styles/first_orbit_bw.json']!,
      ) as Map<String, dynamic>;
      expect(bw['id'], 'first_orbit_bw');
      expect(bw['hue_min'], 0);
      expect(bw['hue_max'], 0);
      expect(bw['main']['value'], [255, 255, 255, 255]);
    });

    test('omits the ending style when only part of the ending is used', () {
      final pack = HexPackBuilder.build(
        draft(ending: true, blackAndWhite: false),
      );
      final level = jsonDecode(
        pack.textFiles['Levels/first_orbit.json']!,
      ) as Map<String, dynamic>;
      final events = (level['events'] as List).cast<Map<String, dynamic>>();

      expect(pack.textFiles, isNot(contains('Styles/first_orbit_bw.json')));
      expect(
        events.map((event) => event['type']),
        isNot(contains('style_set')),
      );
      expect(
        events.map((event) => event['type']),
        contains('level_float_multiply'),
      );
    });

    test('generated Lua has the required callbacks and pattern order', () {
      final pack = HexPackBuilder.build(
        draft().copyWith(
          patterns: [
            HexPatternSelection(kind: HexPatternKind.spiral),
            HexPatternSelection(kind: HexPatternKind.breather),
          ],
          shufflePatterns: false,
        ),
      );
      final lua = pack.textFiles['Scripts/first_orbit.lua']!;

      expect(lua, contains('function onLoad()'));
      expect(lua, contains('function onStep()'));
      expect(lua, contains('function onIncrement()'));
      expect(lua, contains('function onUnload()'));
      expect(lua, contains('function onUpdate(mFrameTime)'));
      expect(lua, contains('local sequence = { "spiral", "breather" }'));
      expect(lua, contains('local intensity = { 2, 2 }'));
      expect(lua, contains('local shufflePatterns = false'));
      expect(lua, contains('dispatchers[sequence[index]]'));
    });

    test('spiral clones the playable VeeDefault mirror spiral', () {
      final pack = HexPackBuilder.build(
        draft().copyWith(
          patterns: [
            HexPatternSelection(kind: HexPatternKind.spiral),
          ],
          shufflePatterns: false,
        ),
      );
      final lua = pack.textFiles['Scripts/first_orbit.lua']!;

      expect(lua, contains('local thickness = THICKNESS * getSpeedMult()'));
      expect(lua, contains('wall(side, thickness)'));
      expect(lua, contains('wall(oppositeOf(side), thickness)'));
      expect(lua, contains('local delay = perfectDelay(thickness)'));
      expect(lua, contains('perfectDelay(THICKNESS) * 6.5'));
    });

    test('music json points at the bundled silent track', () {
      final pack = HexPackBuilder.build(draft());
      final music = jsonDecode(
        pack.textFiles['Music/first_orbit_theme.json']!,
      ) as Map<String, dynamic>;

      expect(music['id'], 'first_orbit_theme');
      expect(music['file_name'], 'first_orbit_theme.ogg');
      expect(music['segments'], [
        {'time': 0},
      ]);
      expect(pack.audioFiles['Music/first_orbit_theme.ogg'],
          HexPackBuilder.silenceAsset);
    });
  });

  group('HexPackExporter', () {
    test('builds a zip containing text files and the silent OGG', () async {
      final bytes = await HexPackExporter.buildZip(draft(ending: true));
      final archive = ZipDecoder().decodeBytes(bytes);
      final names = archive.files.map((file) => file.name).toList();

      expect(names, contains('my_hexagon_pack/pack.json'));
      expect(names, contains('my_hexagon_pack/Levels/first_orbit.json'));
      expect(names, contains('my_hexagon_pack/Music/first_orbit_theme.ogg'));
      expect(names, contains('my_hexagon_pack/Styles/first_orbit_bw.json'));

      final ogg = archive.files.firstWhere(
        (file) => file.name == 'my_hexagon_pack/Music/first_orbit_theme.ogg',
      );
      expect(ogg.size, greaterThan(1000));
      expect(ogg.readBytes()!.take(4).toList(), [79, 103, 103, 83]); // "OggS"
    });
  });
}
