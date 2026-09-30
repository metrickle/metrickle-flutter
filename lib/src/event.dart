/// Property values: string (≤ 1024), finite number, bool or null.
typedef Properties = Map<String, Object?>;

const _maxProperties = 64;

/// Coerces [props] to what ingest accepts: at most 64 keys (≤ 128 chars), strings ≤ 1024,
/// finite numbers (others become null), bools and nulls. Anything else is stringified.
Properties? sanitizeProperties(Map<String, Object?>? props) {
  if (props == null) return null;
  final out = <String, Object?>{};
  for (final MapEntry(:key, :value) in props.entries) {
    if (out.length >= _maxProperties) break;
    final k = key.length > 128 ? key.substring(0, 128) : key;
    out[k] = switch (value) {
      null || bool() => value,
      num() => value.isFinite ? value : null,
      String() => _clip(value, 1024),
      _ => _clip(value.toString(), 1024),
    };
  }
  return out;
}

String _clip(String s, int max) => s.length > max ? s.substring(0, max) : s;

/// One event in an `IngestBatch` (`packages/schema/src/ingest.ts`). Mutable so `beforeSend` can scrub it.
class MetrickleEvent {
  MetrickleEvent({
    required this.id,
    required this.type,
    required this.name,
    required this.ts,
    this.anonymousId,
    this.userId,
    this.sessionId,
    this.url,
    this.path,
    this.title,
    this.referrer,
    this.properties,
    this.traits,
  });

  factory MetrickleEvent.fromJson(Map<String, dynamic> j) => MetrickleEvent(
        id: j['id'] as String,
        type: j['type'] as String,
        name: j['name'] as String,
        ts: (j['ts'] as num).toInt(),
        anonymousId: j['anonymousId'] as String?,
        userId: j['userId'] as String?,
        sessionId: j['sessionId'] as String?,
        url: j['url'] as String?,
        path: j['path'] as String?,
        title: j['title'] as String?,
        referrer: j['referrer'] as String?,
        properties: (j['properties'] as Map?)?.cast<String, Object?>(),
        traits: (j['traits'] as Map?)?.cast<String, Object?>(),
      );

  /// Client-generated UUID, used for dedupe on retries.
  String id;

  /// `page`, `screen`, `track` or `identify`.
  String type;
  String name;

  /// Epoch ms.
  int ts;
  String? anonymousId;
  String? userId;
  String? sessionId;
  String? url;
  String? path;
  String? title;
  String? referrer;
  Properties? properties;
  Properties? traits;

  Map<String, Object?> toJson() => {
        'id': id,
        'type': type,
        'name': name,
        'ts': ts,
        'anonymousId': ?anonymousId,
        'userId': ?userId,
        'sessionId': ?sessionId,
        'url': ?url,
        'path': ?path,
        'title': ?title,
        'referrer': ?referrer,
        'properties': ?properties,
        'traits': ?traits,
      };

  @override
  String toString() => 'MetrickleEvent($type $name ${toJson()})';
}
