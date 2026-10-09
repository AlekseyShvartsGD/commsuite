import 'package:flutter/material.dart';

const _palette = <Color>[
  Color(0xFF00696D),
  Color(0xFF6A1B9A),
  Color(0xFFC62828),
  Color(0xFF2E7D32),
  Color(0xFFE65100),
  Color(0xFF4527A0),
  Color(0xFF00838F),
  Color(0xFF8E24AA),
];

Color avatarColor(String seed) {
  var hash = 0;
  for (final code in seed.codeUnits) {
    hash = (hash * 31 + code) & 0x7FFFFFFF;
  }
  return _palette[hash % _palette.length];
}

class UserAvatar extends StatelessWidget {
  final String? name;
  final String? seed;
  final bool showOnline;
  final double radius;

  const UserAvatar({
    super.key,
    this.name,
    this.seed,
    this.showOnline = false,
    this.radius = 22,
  });

  String get _initials {
    final n = (name ?? seed ?? '?').trim();
    final parts = n.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      return parts.first.characters.take(2).toString().toUpperCase();
    }
    return (parts.first.characters.first + parts.last.characters.first)
        .toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final color = avatarColor(seed ?? name ?? '?');
    final avatar = CircleAvatar(
      radius: radius,
      backgroundColor: color,
      foregroundColor: Colors.white,
      child: Text(
        _initials,
        style: TextStyle(fontSize: radius * 0.85, fontWeight: FontWeight.w600),
      ),
    );
    if (!showOnline) return avatar;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        avatar,
        Positioned(
          right: -radius * 0.15,
          bottom: -radius * 0.15,
          child: Container(
            width: radius * 0.8,
            height: radius * 0.8,
            decoration: BoxDecoration(
              color: Colors.greenAccent,
              shape: BoxShape.circle,
              border: Border.all(
                color: Theme.of(context).colorScheme.surface,
                width: 2,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
