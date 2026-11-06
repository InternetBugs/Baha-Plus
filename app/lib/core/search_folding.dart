import 'package:unorm_dart/unorm_dart.dart' as unicode;

class SearchFolding {
  SearchFolding(this.mapping, {this.traditionalMapping = const {}});
  final Map<String, String> mapping;
  final Map<String, String> traditionalMapping;
  static final _marksAndSpacing = RegExp(
    r'[\u0300-\u036f\u1ab0-\u1aff\u1dc0-\u1dff\u20d0-\u20ff\ufe20-\ufe2f\s\p{P}\p{S}]',
    unicode: true,
  );
  String normalize(String value) {
    final decomposed = unicode.nfkd(value).toLowerCase();
    final folded = StringBuffer();
    for (final rune in decomposed.runes) {
      final character = String.fromCharCode(rune);
      folded.write(mapping[character] ?? character);
    }
    return folded.toString().replaceAll(_marksAndSpacing, '');
  }

  bool matches(String title, String query) =>
      normalize(title).contains(normalize(query));

  String toTraditional(String value) => unicode.nfkc(value).runes.map((rune) {
    final character = String.fromCharCode(rune);
    return traditionalMapping[character] ?? character;
  }).join();
}
