/// U-turn detection, shared by every platform: a user lands on A, moves to B, and comes straight
/// back to A. A short stay on B usually means B was not what they expected (wrong link, confusing
/// label, missing content). Port of `uturn.ts`.
library;

const uTurnMs = 7000;

class UTurn {
  const UTurn({required this.from, required this.to, required this.dwellMs});

  /// The screen the user bounced off.
  final String from;

  /// Where they went back to.
  final String to;
  final int dwellMs;
}

/// Returns a detector to call with each screen name and the time it was shown.
UTurn? Function(String path, int now) uTurnDetector([int thresholdMs = uTurnMs]) {
  ({String path, int t})? prev;
  ({String path, int t})? cur;
  return (path, now) {
    if (cur?.path == path) return null;
    final p = prev, c = cur;
    final hit = p != null && c != null && p.path == path && now - c.t < thresholdMs
        ? UTurn(from: c.path, to: path, dwellMs: now - c.t)
        : null;
    prev = cur;
    cur = (path: path, t: now);
    return hit;
  };
}
