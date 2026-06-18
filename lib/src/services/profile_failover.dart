import '../models/vpn_profile.dart';
import 'profile_store.dart';

enum ProfileLatencyState { ok, failed, unavailable }

class ProfileLatencySnapshot {
  const ProfileLatencySnapshot._({this.milliseconds, required this.state});

  const ProfileLatencySnapshot.ok(int milliseconds)
    : this._(milliseconds: milliseconds, state: ProfileLatencyState.ok);

  const ProfileLatencySnapshot.failed()
    : this._(state: ProfileLatencyState.failed);

  const ProfileLatencySnapshot.unavailable()
    : this._(state: ProfileLatencyState.unavailable);

  final int? milliseconds;
  final ProfileLatencyState state;

  bool get ok => state == ProfileLatencyState.ok && milliseconds != null;

  bool get failed => state == ProfileLatencyState.failed;
}

class RankedProfile {
  const RankedProfile({required this.profile, required this.score});

  final VpnProfile profile;
  final int score;
}

List<RankedProfile> rankProfilesForFailover({
  required List<VpnProfile> profiles,
  required VpnProfile preferred,
  required Map<String, ProfileRuntimeStats> runtimeStats,
  required Map<String, ProfileLatencySnapshot> latencies,
  DateTime? now,
}) {
  final currentTime = now ?? DateTime.now();
  final activeProfiles = profiles
      .where((profile) => !_isExpired(profile, currentTime))
      .toList();
  final candidates = activeProfiles.isEmpty ? profiles : activeProfiles;
  final ranked = candidates
      .map(
        (profile) => RankedProfile(
          profile: profile,
          score: profileFailoverScore(
            profile: profile,
            preferred: preferred,
            runtimeStats: runtimeStats[profile.id],
            latency: latencies[profile.id],
            now: currentTime,
          ),
        ),
      )
      .toList();
  ranked.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) {
      return byScore;
    }
    final aLatency = latencies[a.profile.id]?.milliseconds ?? 1 << 20;
    final bLatency = latencies[b.profile.id]?.milliseconds ?? 1 << 20;
    final byLatency = aLatency.compareTo(bLatency);
    if (byLatency != 0) {
      return byLatency;
    }
    return a.profile.name.compareTo(b.profile.name);
  });
  return ranked;
}

bool shouldAutoSelectBestProfile({
  required VpnProfile preferred,
  required RankedProfile best,
  required Map<String, ProfileRuntimeStats> runtimeStats,
  required Map<String, ProfileLatencySnapshot> latencies,
  DateTime? now,
}) {
  if (best.profile.id == preferred.id) {
    return false;
  }
  final currentTime = now ?? DateTime.now();
  if (_isExpired(preferred, currentTime)) {
    return true;
  }

  final preferredScore = profileFailoverScore(
    profile: preferred,
    preferred: preferred,
    runtimeStats: runtimeStats[preferred.id],
    latency: latencies[preferred.id],
    now: currentTime,
  );
  final preferredStats = runtimeStats[preferred.id];
  final preferredLatency = latencies[preferred.id];
  final scoreGap = best.score - preferredScore;

  if (preferredStats?.unstable == true && scoreGap >= 8) {
    return true;
  }
  if (preferredLatency?.failed == true && scoreGap >= 12) {
    return true;
  }
  return best.score >= 70 && scoreGap >= 20;
}

int profileFailoverScore({
  required VpnProfile profile,
  required VpnProfile preferred,
  required ProfileRuntimeStats? runtimeStats,
  required ProfileLatencySnapshot? latency,
  DateTime? now,
}) {
  final currentTime = now ?? DateTime.now();
  if (_isExpired(profile, currentTime)) {
    return -100000;
  }

  var score = runtimeStats?.score ?? 76;
  if (runtimeStats?.unstable == true) {
    score -= 16;
  }
  score -= (runtimeStats?.consecutiveFailures ?? 0) * 6;

  switch (latency?.state) {
    case ProfileLatencyState.ok:
      final ms = latency!.milliseconds ?? 9999;
      if (ms <= 100) {
        score += 30;
      } else if (ms <= 250) {
        score += 23;
      } else if (ms <= 500) {
        score += 14;
      } else if (ms <= 1000) {
        score += 4;
      } else {
        score -= 8;
      }
      break;
    case ProfileLatencyState.failed:
      score -= 35;
      break;
    case ProfileLatencyState.unavailable:
      score -= 8;
      break;
    case null:
      score -= 2;
      break;
  }

  if ((runtimeStats?.successes ?? 0) > 0) {
    score += (runtimeStats!.successes).clamp(0, 8).toInt();
  }
  if (profile.kind == preferred.kind) {
    score += 3;
  }
  if (profile.subscriptionSource != null &&
      profile.subscriptionSource == preferred.subscriptionSource) {
    score += 4;
  }
  if (profile.id == preferred.id) {
    score += 5;
  }
  return score;
}

bool _isExpired(VpnProfile profile, DateTime now) {
  final expiresAt = profile.expiresAt;
  if (expiresAt == null) {
    return false;
  }
  final expiryDate = DateTime(expiresAt.year, expiresAt.month, expiresAt.day);
  final today = DateTime(now.year, now.month, now.day);
  return expiryDate.isBefore(today);
}
