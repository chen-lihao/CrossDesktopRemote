import 'package:characters/characters.dart';

Iterable<String> chunkRemoteText(
  String text, {
  int maximumUtf16Units = 256,
}) sync* {
  assert(maximumUtf16Units > 0);
  var buffer = StringBuffer();
  var bufferLength = 0;

  for (final grapheme in text.characters) {
    final graphemeLength = grapheme.length;
    if (bufferLength > 0 && bufferLength + graphemeLength > maximumUtf16Units) {
      yield buffer.toString();
      buffer = StringBuffer();
      bufferLength = 0;
    }

    if (graphemeLength <= maximumUtf16Units) {
      buffer.write(grapheme);
      bufferLength += graphemeLength;
      continue;
    }

    // Keep surrogate pairs intact if an intentionally oversized grapheme has
    // to cross the native 256 UTF-16-unit message boundary.
    for (final rune in grapheme.runes) {
      final scalar = String.fromCharCode(rune);
      if (bufferLength > 0 &&
          bufferLength + scalar.length > maximumUtf16Units) {
        yield buffer.toString();
        buffer = StringBuffer();
        bufferLength = 0;
      }
      buffer.write(scalar);
      bufferLength += scalar.length;
    }
  }

  if (bufferLength > 0) yield buffer.toString();
}
