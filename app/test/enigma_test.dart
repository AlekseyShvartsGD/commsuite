import 'package:commsuite/core/enigma.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Enigma I reference vector AAAAA -> BDZGO', () {
    final machine = Enigma();
    expect(machine.encrypt('AAAAA'), 'BDZGO');
  });

  test('Enigma is reciprocal', () {
    final machine = Enigma(plugboard: 'AM FI NV PS TU WZ');
    final text = 'HELLOWORLD';
    final cipher = machine.encrypt(text);
    final again = Enigma(plugboard: 'AM FI NV PS TU WZ').encrypt(cipher);
    expect(again, text);
  });

  test('fixed app encryption is deterministic and case-insensitive', () {
    final a = enigmaEncrypt('secret');
    final b = enigmaEncrypt('SECRET');
    expect(a, b);
    expect(a, isNot('SECRET'));
  });

  test('non-letters pass through without advancing rotors', () {
    final withGap = enigmaEncrypt('AB');
    final split = enigmaEncrypt('A-B');
    expect(split, '${withGap[0]}-${withGap[1]}');
  });
}
