const Map<String, List<int>> _wiring = {
  'I': [4, 10, 12, 5, 11, 6, 3, 16, 21, 25, 13, 19, 14, 22, 24, 7, 23, 20, 18, 15, 0, 8, 1, 17, 2, 9],
  'II': [0, 9, 3, 10, 18, 8, 17, 20, 23, 1, 11, 7, 22, 19, 12, 2, 16, 6, 25, 13, 15, 24, 5, 21, 14, 4],
  'III': [1, 3, 5, 7, 9, 11, 2, 15, 17, 19, 23, 21, 25, 13, 24, 4, 8, 22, 6, 0, 10, 12, 20, 18, 16, 14],
  'IV': [4, 18, 14, 21, 15, 25, 9, 0, 24, 16, 20, 8, 17, 7, 23, 11, 13, 5, 19, 6, 10, 3, 2, 12, 22, 1],
  'V': [21, 25, 1, 17, 6, 8, 19, 24, 20, 15, 18, 3, 13, 7, 11, 23, 0, 22, 12, 9, 16, 14, 5, 4, 2, 10],
};

const Map<String, int> _notches = {'I': 16, 'II': 4, 'III': 21, 'IV': 9, 'V': 25};

const Map<String, List<int>> _reflectors = {
  'A': [4, 9, 12, 25, 0, 11, 24, 23, 21, 1, 22, 5, 2, 17, 16, 20, 14, 13, 19, 18, 15, 8, 10, 7, 6, 3],
  'B': [24, 17, 20, 7, 16, 18, 11, 3, 15, 23, 13, 6, 14, 10, 12, 8, 4, 1, 5, 25, 2, 22, 21, 9, 0, 19],
  'C': [5, 21, 15, 9, 8, 0, 14, 24, 4, 3, 16, 22, 25, 7, 13, 17, 12, 1, 2, 10, 6, 11, 19, 20, 18, 23],
};

class _Rotor {
  _Rotor(this.name, this.wiring)
      : notch = _notches[name]!,
        inverse = List<int>.filled(26, 0) {
    for (var i = 0; i < 26; i++) {
      inverse[wiring[i]] = i;
    }
  }

  final String name;
  final List<int> wiring;
  final List<int> inverse;
  final int notch;
}

class Enigma {
  Enigma({
    List<String> rotors = const ['I', 'II', 'III'],
    this.reflector = 'B',
    String ring = 'AAA',
    String positions = 'AAA',
    String plugboard = '',
  }) : _rotors = rotors.map((name) => _Rotor(name, _wiring[name]!)).toList() {
    _ring = _letterOffsets(ring, _rotors.length);
    _pos = _letterOffsets(positions, _rotors.length);
    _plug = _buildPlugboard(plugboard);
  }

  final List<_Rotor> _rotors;
  final String reflector;
  late final List<int> _ring;
  late final List<int> _pos;
  late final List<int> _plug;

  static List<int> _letterOffsets(String letters, int count) {
    final upper = letters.toUpperCase();
    return List<int>.generate(count, (i) {
      final code = i < upper.length ? upper.codeUnitAt(i) : 65;
      return (code >= 65 && code <= 90) ? code - 65 : 0;
    });
  }

  static List<int> _buildPlugboard(String spec) {
    final plug = List<int>.generate(26, (i) => i);
    final letters = spec.toUpperCase().replaceAll(RegExp('[^A-Z]'), '');
    for (var i = 0; i + 1 < letters.length; i += 2) {
      final a = letters.codeUnitAt(i) - 65;
      final b = letters.codeUnitAt(i + 1) - 65;
      plug[a] = b;
      plug[b] = a;
    }
    return plug;
  }

  int _offset(int i) => ((_pos[i] - _ring[i]) % 26 + 26) % 26;

  bool _atNotch(int i) => _offset(i) == _rotors[i].notch;

  void _step() {
    final middleNotch = _atNotch(1);
    final rightNotch = _atNotch(2);
    if (middleNotch) _pos[0] = (_pos[0] + 1) % 26;
    if (middleNotch || rightNotch) _pos[1] = (_pos[1] + 1) % 26;
    _pos[2] = (_pos[2] + 1) % 26;
  }

  int _forward(int i, int c) {
    final p = _offset(i);
    final idx = (c + p) % 26;
    return (_rotors[i].wiring[idx] - p + 52) % 26;
  }

  int _backward(int i, int c) {
    final p = _offset(i);
    final idx = (c + p) % 26;
    return (_rotors[i].inverse[idx] - p + 52) % 26;
  }

  int _through(int c) {
    var v = _plug[c];
    for (var i = _rotors.length - 1; i >= 0; i--) {
      v = _forward(i, v);
    }
    v = _reflectors[reflector]![v];
    for (var i = 0; i < _rotors.length; i++) {
      v = _backward(i, v);
    }
    return _plug[v];
  }

  String encrypt(String input) {
    final out = StringBuffer();
    for (final code in input.toUpperCase().codeUnits) {
      if (code >= 65 && code <= 90) {
        _step();
        out.writeCharCode(65 + _through(code - 65));
      } else {
        out.writeCharCode(code);
      }
    }
    return out.toString();
  }
}

const String _appPlugboard = 'AM FI NV PS TU WZ';

String enigmaEncrypt(String plaintext) =>
    Enigma(plugboard: _appPlugboard).encrypt(plaintext);
