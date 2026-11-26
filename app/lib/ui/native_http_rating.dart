import 'package:flutter/painting.dart';

/// Visual badge tokens matching the official Bahamut Anime content ratings.
class NativeHttpRatingBadge {
  const NativeHttpRatingBadge({
    required this.codeLabel,
    required this.backgroundColor,
    required this.foregroundColor,
  });

  final String codeLabel;
  final Color backgroundColor;
  final Color foregroundColor;
}

/// The official player's age gate uses token.php's `r18` codes, including a
/// separate code 6 for restricted content that requires age verification.
/// Source: i2.bahamut.com.tw/build/js/anime_player.js, age-gate text and icons.
/// An unrecognized code must not be presented as suitable for all ages.
String nativeHttpRatingMessageKey(int code) => switch (code) {
  1 => 'httpRatingGeneral',
  2 => 'httpRatingProtective',
  3 => 'httpRating12',
  4 => 'httpRating15',
  5 => 'httpRatingRestricted',
  6 => 'httpRatingRestrictedVerified',
  _ => 'httpRatingUnknown',
};

/// Returns the compact color-coded badge metadata for an official `r18` code.
NativeHttpRatingBadge nativeHttpRatingBadge(int code) => switch (code) {
  1 => const NativeHttpRatingBadge(
    codeLabel: '0+',
    backgroundColor: Color(0xFF30D158),
    foregroundColor: Color(0xFF052910),
  ),
  2 => const NativeHttpRatingBadge(
    codeLabel: '6+',
    backgroundColor: Color(0xFF0A84FF),
    foregroundColor: Color(0xFFFFFFFF),
  ),
  3 => const NativeHttpRatingBadge(
    codeLabel: '12+',
    backgroundColor: Color(0xFFFFD60A),
    foregroundColor: Color(0xFF2B2100),
  ),
  4 => const NativeHttpRatingBadge(
    codeLabel: '15+',
    backgroundColor: Color(0xFFFF9F0A),
    foregroundColor: Color(0xFF2E1800),
  ),
  5 || 6 => const NativeHttpRatingBadge(
    codeLabel: '18+',
    backgroundColor: Color(0xFFFF453A),
    foregroundColor: Color(0xFFFFFFFF),
  ),
  _ => const NativeHttpRatingBadge(
    codeLabel: '?',
    backgroundColor: Color(0xFF636366),
    foregroundColor: Color(0xFFFFFFFF),
  ),
};
