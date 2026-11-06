import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../hexagon/hexagon_models.dart';

class HexPreviewWall {
  const HexPreviewWall({
    required this.side,
    required this.start,
    required this.travel,
    required this.thickness,
  });

  final int side;
  final double start;
  final double travel;

  /// Wall thickness as a fraction of the arena radius.
  final double thickness;
}

class HexPreviewTimeline {
  const HexPreviewTimeline({
    required this.walls,
    required this.duration,
    required this.blackAndWhiteStart,
  });

  final List<HexPreviewWall> walls;
  final double duration;

  /// Time in the loop where the B&W ending kicks in, or null when disabled.
  final double? blackAndWhiteStart;
}

/// Approximates the generated Lua timeline closely enough to recognize each
/// pattern family and the pace of the level.
HexPreviewTimeline buildHexPreviewTimeline(HexMapDraft draft) {
  final random = math.Random(0x51D0);
  final walls = <HexPreviewWall>[];
  final sides = draft.sides.clamp(3, 10);
  final travel = (1.05 / (0.72 + draft.speedMultiplier * 0.28)).clamp(0.42, 1.6);
  var time = 0.0;

  int wrapSide(int side) => ((side % sides) + sides) % sides;
  int oppositeOf(int side) => wrapSide(side + sides ~/ 2);

  void addWall(int side, double start, double thickness) {
    walls.add(
      HexPreviewWall(
        side: wrapSide(side),
        start: start,
        travel: travel,
        thickness: thickness,
      ),
    );
  }

  for (final selection in draft.patterns) {
    final level = selection.intensity.clamp(1, 3);
    switch (selection.kind) {
      case HexPatternKind.barrage:
        final side = random.nextInt(sides);
        final count = 3 + level;
        var at = time;
        for (var i = 0; i < count; i++) {
          addWall(side, at, 0.052 + 0.008 * level);
          at += 0.3;
        }
        time = at + 0.55;
      case HexPatternKind.spiral:
        // Mirrors VeeDefault's pMirrorSpiral: thick mirrored walls with a full
        // perfect delay between steps, which is what keeps it playable.
        var side = random.nextInt(sides);
        final direction = random.nextBool() ? 1 : -1;
        final count = 3 + level;
        var at = time;
        for (var i = 0; i < count; i++) {
          addWall(side, at, 0.085);
          addWall(oppositeOf(side), at, 0.085);
          side = wrapSide(side + direction);
          at += 0.62;
        }
        time = at + 1.0;
      case HexPatternKind.alternate:
        final side = random.nextInt(sides);
        final opposite = oppositeOf(side);
        final count = 3 + level;
        var at = time;
        for (var i = 0; i < count; i++) {
          addWall(side, at, 0.06);
          addWall(opposite, at + 0.8, 0.06);
          at += 1.6;
        }
        time = at + 0.6;
      case HexPatternKind.tunnel:
        final side = random.nextInt(sides);
        addWall(side, time, 0.075 + 0.008 * level);
        addWall(oppositeOf(side), time, 0.075 + 0.008 * level);
        time += 1.15;
      case HexPatternKind.zipper:
        var side = random.nextInt(sides);
        final direction = random.nextBool() ? 1 : -1;
        final count = 4 + level;
        var at = time;
        for (var i = 0; i < count; i++) {
          addWall(side, at, 0.058);
          addWall(side + direction, at, 0.048);
          side = wrapSide(side + direction);
          at += 0.34;
        }
        time = at + 0.5;
      case HexPatternKind.mirror:
        var side = random.nextInt(sides);
        var opposite = oppositeOf(side);
        final count = 2 + level;
        var at = time;
        for (var i = 0; i < count; i++) {
          addWall(side, at, 0.06);
          addWall(opposite, at, 0.06);
          side = wrapSide(side + 1);
          opposite = wrapSide(opposite - 1);
          at += 0.42;
        }
        time = at + 0.45;
      case HexPatternKind.sweep:
        var side = random.nextInt(sides);
        final direction = random.nextBool() ? 1 : -1;
        final count = sides - 1;
        var at = time;
        for (var i = 0; i < count; i++) {
          addWall(side, at, 0.058);
          side = wrapSide(side + direction);
          at += 0.28;
        }
        time = at + 0.5;
      case HexPatternKind.breather:
        time += 1.2;
    }
  }

  if (walls.isEmpty) {
    walls.add(
      HexPreviewWall(side: 0, start: 0, travel: travel, thickness: 0.06),
    );
  }

  final lastArrival = walls.fold<double>(
    0,
    (latest, wall) => math.max(latest, wall.start + wall.travel),
  );
  final duration = math.max(6.0, lastArrival + 0.7);
  final ending = draft.ending;
  final blackAndWhiteStart =
      ending.enabled && ending.blackAndWhite ? duration * 0.7 : null;

  return HexPreviewTimeline(
    walls: walls,
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
        draft.speedMultiplier,
        draft.rotationSpeed,
        draft.fastSpin,
        draft.shufflePatterns,
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
    final theme = Theme.of(context);
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
              final seconds = _controller.value * _timeline.duration;
              final auto = widget.rotateCamera
                  ? seconds * (0.32 + widget.draft.rotationSpeed * 2.6)
                  : 0.0;
              final bwStart = _timeline.blackAndWhiteStart;
              final blackAndWhite = bwStart != null && seconds >= bwStart;
              return CustomPaint(
                painter: _HexPreviewPainter(
                  timeline: _timeline,
                  seconds: seconds,
                  sides: widget.draft.sides.clamp(3, 10),
                  palette: widget.draft.palette,
                  blackAndWhite: blackAndWhite,
                  rotation: auto + _manualRotation,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: Text(
                          blackAndWhite
                              ? 'ending · black & white'
                              : 'drag to orbit · ${widget.draft.sides} sides',
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                    ),
                  ),
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
    required this.seconds,
    required this.sides,
    required this.palette,
    required this.blackAndWhite,
    required this.rotation,
  });

  final HexPreviewTimeline timeline;
  final double seconds;
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
      HexPalette.neon =>
        HSVColor.fromAHSV(1, (168 + side * 33) % 150 + 168, 0.62, 1).toColor(),
      HexPalette.ember =>
        HSVColor.fromAHSV(1, 8 + (side * 9) % 46, 0.82, 1).toColor(),
      HexPalette.ocean =>
        HSVColor.fromAHSV(1, 178 + (side * 17) % 70, 0.72, 1).toColor(),
      HexPalette.mono => Colors.white,
    };
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final shortest = math.min(size.width, size.height);
    final radius = shortest * 0.29;
    final apothem = radius * math.cos(math.pi / sides);
    final halfLength = radius * math.sin(math.pi / sides) * 0.97;
    final outer = apothem + radius * 0.55;

    // Flat, dark backdrop. No white halo, no additive glow.
    canvas.drawRect(Offset.zero & size, Paint()..color = _background);

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(rotation);

    // Exactly one arena hexagon: a tinted fill and a thick outline.
    final hexagon = _polygonPath(radius, sides);
    canvas.drawPath(
      hexagon,
      Paint()
        ..color = Color.lerp(
          _background,
          _accent(0),
          blackAndWhite ? 0.04 : 0.10,
        )!,
    );
    canvas.drawPath(
      hexagon,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = radius * 0.035
        ..strokeJoin = StrokeJoin.miter
        ..color = _accent(0).withValues(alpha: 0.9),
    );

    // Every obstacle keeps its size while it travels. Drawing the full swept
    // path of all obstacles and merging them produces the six chevron bands
    // that sit around the arena.
    for (final wall in timeline.walls) {
      final angle = (wall.side + 0.5) * 2 * math.pi / sides - math.pi / 2;
      final normal = Offset(math.cos(angle), math.sin(angle));
      final tangent = Offset(-math.sin(angle), math.cos(angle));
      final innerMid = normal * apothem;
      final outerMid = normal * outer;
      final color = _accent(wall.side);
      final half = tangent * halfLength;

      // Outline of the swept obstacle path. Merging the paths of every
      // obstacle leaves the chevron outlines around the arena.
      final edgePaint = Paint()
        ..color = color.withValues(alpha: 0.42)
        ..strokeWidth = math.max(1.0, radius * 0.014)
        ..strokeCap = StrokeCap.butt;
      canvas.drawLine(innerMid - half, outerMid - half, edgePaint);
      canvas.drawLine(innerMid + half, outerMid + half, edgePaint);
      canvas.drawLine(innerMid - half, innerMid + half, edgePaint);
      canvas.drawLine(outerMid - half, outerMid + half, edgePaint);
    }

    // A bright dash slides inward along each path, so the merged pattern still
    // shows where the obstacles are travelling. Its size stays constant.
    for (final wall in timeline.walls) {
      final progress = (seconds - wall.start) / wall.travel;
      if (progress < 0 || progress > 1) continue;
      final angle = (wall.side + 0.5) * 2 * math.pi / sides - math.pi / 2;
      final normal = Offset(math.cos(angle), math.sin(angle));
      final tangent = Offset(-math.sin(angle), math.cos(angle));
      final half = tangent * halfLength;
      final distance = outer + (apothem - outer) * progress;
      final mid = normal * distance;
      canvas.drawLine(
        mid - half,
        mid + half,
        Paint()
          ..color = _accent(wall.side).withValues(alpha: 0.95)
          ..strokeWidth = math.max(2.0, radius * 0.022)
          ..strokeCap = StrokeCap.butt,
      );
    }

    canvas.restore();
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
