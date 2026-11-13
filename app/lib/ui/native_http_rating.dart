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
