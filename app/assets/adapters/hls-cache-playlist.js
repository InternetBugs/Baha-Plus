// Shared by the native JavaScriptCore playlist parser and offline Node tests.
// Resolution and resource registration belong to the native origin allowlist.
function parseHlsCachePlaylist(text, resolve, rewrite, role) {
  if (typeof text !== 'string' || text.length > 500000 ||
      !text.trimStart().startsWith('#EXTM3U')) throw Error('Invalid HLS playlist');
  var lines = text.split(/\r?\n/), output = [], segments = [];
  var time = 0, duration = null, key = null, map = null, nextPlaylist = false;
  var endList = false;
  function resource(raw, kind, track) {
    var url = resolve(raw);
    if (!url) throw Error('Unsupported HLS resource');
    var local = rewrite(url, kind, track || role || 'video');
    if (!local) throw Error('Unsupported HLS resource');
    return {url: url, local: local};
  }
  for (var index = 0; index < lines.length; index++) {
    var line = lines[index].trim();
    if (line.startsWith('#EXTINF:')) {
      duration = Number(line.slice(8).split(',')[0]);
      if (!Number.isFinite(duration) || duration <= 0 || duration > 3600)
        throw Error('Invalid HLS duration');
    }
    if (line === '#EXT-X-ENDLIST') endList = true;
    if (line.startsWith('#EXT-X-KEY:') && /(?:[:,])METHOD=NONE(?:,|$)/.test(line)) key = null;
    if (line.startsWith('#EXT-X-STREAM-INF:')) nextPlaylist = true;
    if (line.startsWith('#') && /(?:[:,])URI="/.test(line)) {
      var tag = line.split(':')[0];
      var kind = tag === '#EXT-X-KEY' || tag === '#EXT-X-SESSION-KEY' ? 'key' :
        tag === '#EXT-X-MAP' ? 'init' : 'playlist';
      var track = tag === '#EXT-X-MEDIA' && /(?:[:,])TYPE=AUDIO(?:,|$)/.test(line) ? 'audio' :
        tag === '#EXT-X-MEDIA' && /(?:[:,])TYPE=SUBTITLES(?:,|$)/.test(line) ? 'subtitles' :
        tag === '#EXT-X-I-FRAME-STREAM-INF' ? 'iframes' : role;
      line = line.replace(/((?:[:,])URI=")([^"]+)"/g, function (_, prefix, raw) {
        var item = resource(raw, kind, track);
        if (tag === '#EXT-X-KEY') key = item.url;
        if (tag === '#EXT-X-MAP') map = item.url;
        return prefix + item.local + '"';
      });
    } else if (line && !line.startsWith('#')) {
      var item = resource(line, nextPlaylist ? 'playlist' : 'segment', role);
      if (!nextPlaylist && duration !== null) {
        segments.push({
          url: item.url, start: time, duration: duration,
          dependencies: [key, map].filter(function (value) { return value !== null; })
        });
        time += duration;
        duration = null;
      }
      nextPlaylist = false;
      line = item.local;
    }
    output.push(line);
  }
  if (segments.length > 20000) throw Error('HLS playlist too large');
  return {text: output.join('\n'), segments: segments, endList: endList};
}
