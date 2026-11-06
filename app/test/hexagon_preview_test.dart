import 'package:flutter_test/flutter_test.dart';

import 'package:commsuite/hexagon/hexagon_models.dart';
import 'package:commsuite/screens/hexagon/hexagon_preview.dart';

void main() {
  test('preview builds one obstacle band per pattern in order', () {
    final draft = HexMapDraft.defaults().copyWith(
      patterns: [
        HexPatternSelection(kind: HexPatternKind.barrage, intensity: 1),
        HexPatternSelection(kind: HexPatternKind.spiral, intensity: 2),
        HexPatternSelection(kind: HexPatternKind.alternate, intensity: 3),
      ],
    );

    final timeline = buildHexPreviewTimeline(draft);

    expect(timeline.bands, hasLength(3));
    expect(timeline.bands.map((band) => band.kind), [
      HexPatternKind.barrage,
      HexPatternKind.spiral,
      HexPatternKind.alternate,
    ]);
    expect(timeline.bands.map((band) => band.intensity), [1, 2, 3]);
  });

  test('preview falls back to a single band when no patterns are selected', () {
    final draft = HexMapDraft.defaults().copyWith(patterns: []);

    final timeline = buildHexPreviewTimeline(draft);

    expect(timeline.bands, hasLength(1));
  });

  test('preview tracks the black-and-white ending window', () {
    final draft = HexMapDraft.defaults().copyWith(
      ending: const HexEnding(enabled: true, blackAndWhite: true),
    );

    final timeline = buildHexPreviewTimeline(draft);

    expect(timeline.blackAndWhiteStart, isNotNull);
    expect(timeline.blackAndWhiteStart, closeTo(timeline.duration * 0.7, 1e-9));
  });

  test('preview has no black-and-white window when the ending is off', () {
    final draft = HexMapDraft.defaults().copyWith(
      ending: const HexEnding(enabled: false, blackAndWhite: true),
    );

    final timeline = buildHexPreviewTimeline(draft);

    expect(timeline.blackAndWhiteStart, isNull);
  });
}
