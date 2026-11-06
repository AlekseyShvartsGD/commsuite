import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../hexagon/hexagon_models.dart';

/// One obstacle region in the preview.
///
/// The reference layout shows each pattern as a solid, elongated band that
/// sits outside the arena and runs parallel to one of its sides. The band is
/// the merged result of moving a constant-size obstacle across the pattern's
/// sides: a trapezoid with bevelled ends, never a rectangle or a square.
class HexPreviewBand {
  const HexPreviewBand({
    required this.slot,
    required this.kind,
    required this.intensity,
  });

  /// Position around the arena, used for the palette accent.
  final int slot;
  final HexPatternKind kind;

  /// 1 = calm, 2 = brisk, 3 = wild.
  final int intensity;
}

class HexPreviewTimeline {
  const HexPreviewTimeline({
    required this.bands,
    required this.duration,
    required this.blackAndWhiteStart,
  });

  final List<HexPreviewBand> bands;
  final double duration;

  /// Time in the loop where the B&W ending kicks in, or null when disabled.
  final double? blackAndWhiteStart;
}

/// Builds the static pattern map that the preview draws: one obstacle band per
/// pattern, spread evenly around the arena. With three patterns this matches
/// the reference exactly (bands at 0°, 120° and 240°); with six every side of
/// the hexagon gets one.
HexPreviewTimeline buildHexPreviewTimeline(HexMapDraft draft) {
  final selections = draft.patterns;
  final bands = <HexPreviewBand>[];
  for (var i = 0; i < selections.length; i++) {
    bands.add(
      HexPreviewBand(
        slot: i,
        kind: selections[i].kind,
        intensity: selections[i].intensity.clamp(1, 3),
      ),
    );
  }
  if (bands.isEmpty) {
    bands.add(
      const HexPreviewBand(slot: 0, kind: HexPatternKind.barrage, intensity: 2),
    );
  }

  final duration = (6.0 + bands.length * 1.6).clamp(6.0, 30.0);
  final ending = draft.ending;
  final blackAndWhiteStart = ending.enabled && ending.blackAndWhite
      ? duration * 0.7
      : null;

  return HexPreviewTimeline(
    bands: bands,
    duration: duration,
    blackAndWhiteStart: blackAndWhiteStart,
  );
}

class HexPreview extends StatefulWidget {
  const HexPreview({
    super.key,
    required this.draft,
    this.rotateCamera = true,
    this.height = 220,
  });

  final HexMapDraft draft;

  /// Orbit the arena continuously, like Open Hexagon's rotation camera.
  final bool rotateCamera;
  final double height;

  @override
  State<HexPreview> createState() => _HexPreviewState();
}

class _HexPreviewState extends State<HexPreview>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late HexPreviewTimeline _timeline;
  late String _timelineKey;
  double _manualRotation = 0;

  String _keyFor(HexMapDraft draft) => [
    draft.sides,
    draft.ending.enabled,
    draft.ending.blackAndWhite,
    for (final pattern in draft.patterns)
      '${pattern.kind.name}:${pattern.intensity}',
  ].join('|');

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
    _timelineKey = _keyFor(widget.draft);
    _timeline = buildHexPreviewTimeline(widget.draft);
    _restart();
  }

  @override
  void didUpdateWidget(covariant HexPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextKey = _keyFor(widget.draft);
    if (nextKey != _timelineKey) {
      _timelineKey = nextKey;
      _timeline = buildHexPreviewTimeline(widget.draft);
      _restart();
    }
  }

  void _restart() {
    _controller
      ..stop()
      ..duration = Duration(
        milliseconds: (_timeline.duration * 1000).round().clamp(2000, 120000),
      )
      ..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        child: GestureDetector(
          onPanUpdate: (details) {
            setState(() => _manualRotation += details.delta.dx * 0.012);
          },
          onDoubleTap: () => setState(() => _manualRotation = 0),
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              // Whole turns per loop keep the orbit continuous across repeats.
              final turns = (1 + widget.draft.rotationSpeed * 10).round().clamp(
                1,
                8,
              );
              final auto = widget.rotateCamera
                  ? _controller.value * 2 * math.pi * turns
                  : 0.0;
              final seconds = _controller.value * _timeline.duration;
              final bwStart = _timeline.blackAndWhiteStart;
              final blackAndWhite = bwStart != null && seconds >= bwStart;
              return CustomPaint(
                painter: _HexPreviewPainter(
                  timeline: _timeline,
                  sides: widget.draft.sides.clamp(3, 10),
                  palette: widget.draft.palette,
                  blackAndWhite: blackAndWhite,
                  rotation: auto + _manualRotation,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _HexPreviewPainter extends CustomPainter {
  _HexPreviewPainter({
    required this.timeline,
    required this.sides,
    required this.palette,
    required this.blackAndWhite,
    required this.rotation,
  });

  final HexPreviewTimeline timeline;
  final int sides;
  final HexPalette palette;
  final bool blackAndWhite;
  final double rotation;

  Color get _background {
    if (blackAndWhite) return Colors.black;
    return switch (palette) {
      HexPalette.neon => const Color(0xFF070B12),
      HexPalette.ember => const Color(0xFF120804),
      HexPalette.ocean => const Color(0xFF040C14),
      HexPalette.mono => const Color(0xFF101010),
    };
  }

  Color _accent(int side) {
    if (blackAndWhite) return Colors.white;
    return switch (palette) {
      HexPalette.neon => HSVColor.fromAHSV(
        1,
        (168 + side * 33) % 150 + 168,
        0.62,
        1,
      ).toColor(),
      HexPalette.ember => HSVColor.fromAHSV(
        1,
        8 + (side * 9) % 46,
        0.82,
        1,
      ).toColor(),
      HexPalette.ocean => HSVColor.fromAHSV(
        1,
        178 + (side * 17) % 70,
        0.72,
        1,
      ).toColor(),
      HexPalette.mono => Colors.white,
    };
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final shortest = math.min(size.width, size.height);
    final radius = shortest * 0.13;

    // Flat backdrop. No halo, glow or additive white shader.
    canvas.drawRect(Offset.zero & size, Paint()..color = _background);

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(rotation);

    // Exactly one arena polygon, drawn as a single thick outline.
    canvas.drawPath(
      _polygonPath(radius, sides),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.5, radius * 0.07)
        ..strokeJoin = StrokeJoin.miter
        ..color = _accent(0).withValues(alpha: blackAndWhite ? 0.95 : 0.85),
    );

    _paintBands(canvas, shortest);

    canvas.restore();
  }

  void _paintBands(Canvas canvas, double shortest) {
    final count = timeline.bands.length;
    if (count == 0) return;

    // The reference places the bands well outside the arena, tangent to it,
    // one per pattern. The size is fixed: it never shrinks as the camera turns
    // or as more patterns are added. With a full set of six the ends overlap
    // at the arena corners, so the obstacles read as one connected frame.
    final bandRadius = shortest * 0.36;
    final baseWidth = shortest * 0.062;

    for (var i = 0; i < count; i++) {
      final band = timeline.bands[i];
      final angle = i * 2 * math.pi / count;
      final normal = Offset(math.cos(angle), math.sin(angle));
      final tangent = Offset(-math.sin(angle), math.cos(angle));

      final width = baseWidth * (0.92 + 0.04 * band.intensity);
      final halfOuter = (bandRadius * math.tan(math.pi / sides) * 1.15).clamp(
        shortest * 0.12,
        shortest * 0.26,
      );
      // The ends are bevelled, so the inner edge is shorter than the outer one.
      final halfInner = math.max(0.0, halfOuter - width * 0.58);

      final mid = normal * bandRadius;
      final outer = mid + normal * (width / 2);
      final inner = mid - normal * (width / 2);

      final path = Path()
        ..moveTo(
          outer.dx - tangent.dx * halfOuter,
          outer.dy - tangent.dy * halfOuter,
        )
        ..lineTo(
          outer.dx + tangent.dx * halfOuter,
          outer.dy + tangent.dy * halfOuter,
        )
        ..lineTo(
          inner.dx + tangent.dx * halfInner,
          inner.dy + tangent.dy * halfInner,
        )
        ..lineTo(
          inner.dx - tangent.dx * halfInner,
          inner.dy - tangent.dy * halfInner,
        )
        ..close();

      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.fill
          ..color = _accent(band.slot)
              .withValues(alpha: blackAndWhite ? 0.96 : 0.88),
      );
    }
  }

  Path _polygonPath(double radius, int sides) {
    final path = Path();
    for (var i = 0; i < sides; i++) {
      final angle = i * 2 * math.pi / sides - math.pi / 2;
      final point = Offset(math.cos(angle) * radius, math.sin(angle) * radius);
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    return path..close();
  }

  @override
  bool shouldRepaint(covariant _HexPreviewPainter oldDelegate) => true;
}
