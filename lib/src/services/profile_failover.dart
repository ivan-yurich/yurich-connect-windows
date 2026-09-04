import '../models/vpn_profile.dart';
import 'profile_store.dart';
import 'vless_profile_tools.dart';

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

class ProfileFailoverSelection {
  const ProfileFailoverSelection({
    required this.candidates,
    this.autoSelectedProfile,
  });

  final List<VpnProfile> candidates;
  final VpnProfile? autoSelectedProfile;
}

List<VpnProfile> profileFailoverPool({
  required List<VpnProfile> profiles,
  required VpnProfile preferred,
  required bool adaptiveAccess,
}) {
  if (adaptiveAccess || !VlessProfileTools.isVlessProfile(preferred)) {
    return List.unmodifiable(profiles);
  }
  return List.unmodifiable(profiles.where(VlessProfileTools.isVlessProfile));
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
  final nonQuarantinedProfiles = activeProfiles
      .where(
        (profile) =>
            runtimeStats[profile.id]?.isQuarantined(currentTime) != true,
      )
      .toList();
  final ranked = nonQuarantinedProfiles
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
    final byGroup = _profileFailoverGroupPriority(
      a.profile,
      preferred,
    ).compareTo(_profileFailoverGroupPriority(b.profile, preferred));
    if (byGroup != 0) {
      return byGroup;
    }
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

ProfileFailoverSelection selectProfileFailoverCandidates({
  required List<VpnProfile> profiles,
  required VpnProfile preferred,
  required Map<String, ProfileRuntimeStats> runtimeStats,
  required Map<String, ProfileLatencySnapshot> latencies,
  int maxAttempts = 3,
  DateTime? now,
}) {
  if (maxAttempts < 1) {
    throw RangeError.range(maxAttempts, 1, null, 'maxAttempts');
  }
  final currentTime = now ?? DateTime.now();
  final ranked = rankProfilesForFailover(
    profiles: profiles,
    preferred: preferred,
    runtimeStats: runtimeStats,
    latencies: latencies,
    now: currentTime,
  );
  if (ranked.isEmpty) {
    return ProfileFailoverSelection(candidates: [preferred]);
  }

  final best = ranked.first;
  final useBest = shouldAutoSelectBestProfile(
    preferred: preferred,
    best: best,
    runtimeStats: runtimeStats,
    latencies: latencies,
    now: currentTime,
  );
  final preferredEligible =
      !_isExpired(preferred, currentTime) &&
      runtimeStats[preferred.id]?.isQuarantined(currentTime) != true;
  final ordered = <VpnProfile>[];

  void add(VpnProfile profile) {
    if (!ordered.any((item) => item.id == profile.id)) {
      ordered.add(profile);
    }
  }

  if (useBest) {
    add(best.profile);
  } else if (preferredEligible) {
    add(preferred);
  }

  for (final candidate in ranked) {
    add(candidate.profile);
    if (ordered.length >= maxAttempts) {
      break;
    }
  }

  return ProfileFailoverSelection(
    candidates: List.unmodifiable(ordered.take(maxAttempts)),
    autoSelectedProfile: useBest ? best.profile : null,
  );
}

String? startupProbeQuarantineReason({
  required VpnProfileKind profileKind,
  required Iterable<String> failureClasses,
}) {
  final failures = failureClasses.toList(growable: false);
  if (failures.length < 2) {
    return null;
  }

  const upstreamFailureClasses = {
    'proxy_probe_timeout',
    'tcp',
    'socket',
    'route',
  };
  final upstreamFailures = failures
      .where(upstreamFailureClasses.contains)
      .length;
  final quorum = (failures.length * 0.75).ceil();
  if (upstreamFailures < quorum) {
    return null;
  }

  return switch (profileKind) {
    VpnProfileKind.vlessReality ||
    VpnProfileKind.vlessTls => 'vless_upstream_unreachable',
    VpnProfileKind.naive => 'naive_upstream_unreachable',
    VpnProfileKind.hysteria ||
    VpnProfileKind.hysteria2 => 'hysteria_upstream_unreachable',
    VpnProfileKind.singBoxConfig => 'proxy_upstream_unreachable',
  };
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
  if (runtimeStats[preferred.id]?.isQuarantined(currentTime) == true) {
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
  if (runtimeStats?.isQuarantined(currentTime) == true) {
    score -= 80;
  }
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

int _profileFailoverGroupPriority(VpnProfile profile, VpnProfile preferred) {
  if (VlessProfileTools.isVlessProfile(preferred) &&
      VlessProfileTools.isVlessProfile(profile)) {
    return _vlessFailoverGroupPriority(profile, preferred);
  }

  final sameProtocol = profile.kind == preferred.kind;
  final sameSubscription =
      profile.subscriptionSource != null &&
      profile.subscriptionSource == preferred.subscriptionSource;
  final profileRegion = _profileRegionKey(profile);
  final preferredRegion = _profileRegionKey(preferred);
  final sameRegion =
      profileRegion.isNotEmpty && profileRegion == preferredRegion;

  if (sameProtocol && sameRegion) {
    return 1;
  }
  if (sameProtocol && sameSubscription) {
    return 2;
  }
  if (sameProtocol) {
    return 3;
  }
  if (sameRegion) {
    return 4;
  }
  if (sameSubscription) {
    return 5;
  }
  return 6;
}

int _vlessFailoverGroupPriority(VpnProfile profile, VpnProfile preferred) {
  final sameKind = profile.kind == preferred.kind;
  final sameTransport =
      VlessProfileTools.safeTransportType(profile) ==
      VlessProfileTools.safeTransportType(preferred);
  final sameSubscription =
      profile.subscriptionSource != null &&
      profile.subscriptionSource == preferred.subscriptionSource;
  final profileRegion = _profileRegionKey(profile);
  final preferredRegion = _profileRegionKey(preferred);
  final sameRegion =
      profileRegion.isNotEmpty && profileRegion == preferredRegion;

  if (sameTransport && sameRegion) {
    return 1;
  }
  if (sameTransport && sameSubscription) {
    return 2;
  }
  if (sameTransport) {
    return 3;
  }
  if (sameKind && sameRegion) {
    return 4;
  }
  if (sameKind) {
    return 5;
  }
  if (sameRegion) {
    return 6;
  }
  if (sameSubscription) {
    return 7;
  }
  return 8;
}

String _profileRegionKey(VpnProfile profile) {
  final source = '${profile.name} ${profile.server ?? ''}'.toLowerCase();
  const regions = {
    'ru': [' russia', 'moscow', '.ru', 'russia'],
    'fi': [' finland', 'helsinki', '.fi', 'finland'],
    'de': [' germany', 'deutschland', 'frankfurt', '.de', 'germany'],
    'nl': [' netherlands', 'amsterdam', '.nl', 'netherlands'],
    'fr': [' france', 'paris', '.fr', 'france'],
    'pl': [' poland', 'warsaw', '.pl', 'poland'],
    'gb': [' united kingdom', 'london', '.uk', 'united kingdom'],
    'us': [' usa', 'united states', 'new york', '.us', 'usa'],
  };
  for (final entry in regions.entries) {
    if (entry.value.any(source.contains)) {
      return entry.key;
    }
  }
  final server = profile.server?.toLowerCase();
  if (server == null || server.isEmpty) {
    return '';
  }
  final parts = server.split('.');
  if (parts.length < 2) {
    return '';
  }
  final tld = parts.last;
  return tld.length == 2 ? tld : '';
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
