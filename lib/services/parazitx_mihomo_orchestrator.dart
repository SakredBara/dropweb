/// Bridges [ParazitXManager.bridgeInfo] state into Mihomo config patching.
///
/// Called from `GlobalState.patchRawConfig` while assembling the active
/// Mihomo configuration. When a ParazitX bridge endpoint is currently
/// advertised, this orchestrator delegates to [MihomoDialerProxyPatcher]
/// to inject the local SOCKS5 outbound and append it to the `GLOBAL`
/// proxy-group (recommendation A from the 2026-05-02 plan): the bridge
/// becomes a *selectable* option without overriding the user's selected
/// or default proxy. When no bridge is active the orchestrator is a
/// no-op — the next subscription-driven config rebuild produces a clean
/// config without any ParazitX entries, which is how cleanup happens.
///
/// Self-loop protection (Task 6 of the 2026-05-02 plan):
///
/// When ParazitX is Mihomo's outbound, mihomo would otherwise route the
/// relay's own signaling/init sockets through ParazitX SOCKS, creating a
/// loop back into the relay. The Go relay does not (yet) expose Android
/// `VpnService.protect(fd)` — verified in Task 6: zero matches for
/// `Protect`/`protect`/`VpnService` across `parazitx/relay/...`. As a
/// temporary fallback, this orchestrator computes a list of DIRECT
/// rules and prepends them to mihomo's rule chain so the relay's
/// bootstrap traffic bypasses mihomo's TUN.
///
/// The DIRECT rule set covers:
///   * VK signaling/call endpoints used by relay (vk.com, vkuser*.com,
///     vk-cdn, etc.) — relay's `vk_auth.go` / `vk_joiner.go` reach these
///     directly when establishing the call.
///   * Yandex Telemost endpoints (cloud-api.yandex.ru, telemost.yandex.ru)
///     for the Telemost variant of the joiner.
///   * Yandex API Gateway init endpoint(s) — when the active subscription
///     supplies `dropweb-parazitx-relays` URLs (these are session-kind
///     relays that ParazitX itself dials during activation).
///   * Configured callfactory backend `host:port` entries (from the
///     subscription `dropweb-parazitx-servers` header) — relay's direct
///     dial path during activation.
///
/// This is less robust than `protect(fd)` (we have to enumerate hosts
/// instead of binding to the underlying network at the socket level)
/// but it is the available primitive given the upstream relay
/// constraints.
///
/// Subscription ownership is preserved:
///   * Existing groups are never created. If `GLOBAL` is absent the
///     bridge is added to `proxies` only — no group append.
///   * `default` / `selected` / any other group field stays untouched.
///   * Existing rules are never reordered or dropped — DIRECT rules
///     are PREPENDED so they win over any catch-all `MATCH,...` from
///     the subscription, and duplicates are skipped.
///   * Rule-providers / DNS / TUN are never modified.
library;

import 'dart:developer' as developer;

import '../models/models.dart';
import '../state.dart';
import 'log_buffer.dart';
import 'mihomo_dialer_proxy_patcher.dart';
import 'parazitx_manager.dart';

/// Group name that the ParazitX bridge is appended to when present.
/// Plan recommendation A: append to `GLOBAL` if it exists; never force
/// selection or invent a group.
const _kDefaultBridgeGroup = 'GLOBAL';

/// Subscription provider header name carrying explicit `host:port`
/// callfactory backends. Mirrored from
/// `lib/services/parazitx_manager.dart::_serversHeaderName`. Kept as a
/// private constant here so the orchestrator stays loosely coupled
/// (no cross-import of private members).
const _kServersHeaderName = 'dropweb-parazitx-servers';

/// Subscription provider header name carrying signaling-relay HTTPS
/// URLs. Mirrored from `parazitx_manager.dart::_relaysHeaderName`.
const _kRelaysHeaderName = 'dropweb-parazitx-relays';

/// Static DIRECT rule set: well-known VK signaling endpoints that the
/// relay reaches during call establishment + Telemost APIs for the
/// Telemost joiner variant. These never change with subscription state.
///
/// Ordering matters: more-specific rules first (DOMAIN > DOMAIN-SUFFIX),
/// IPv4 IP-CIDR variants before catch-all suffixes.
///
/// Source: grep'd through
/// `parazitx/relay/pion/headless-joiner-common/{vk_auth,vk_joiner,
/// telemost_joiner,captcha_proxy}.go` for hardcoded HTTP(S) endpoints.
const _kStaticDirectRules = <String>[
  // VK auth + signaling (Origin/Referer plus actual API requests).
  'DOMAIN-SUFFIX,vk.com,DIRECT',
  'DOMAIN-SUFFIX,vkuser.net,DIRECT',
  'DOMAIN-SUFFIX,vkuserlive.net,DIRECT',
  'DOMAIN-SUFFIX,vkuservideo.net,DIRECT',
  'DOMAIN-SUFFIX,vk-cdn.net,DIRECT',
  'DOMAIN-SUFFIX,userapi.com,DIRECT',
  // Yandex Telemost API + signaling.
  'DOMAIN-SUFFIX,yandex.ru,DIRECT',
  'DOMAIN-SUFFIX,yandex.net,DIRECT',
  // Yandex Cloud API Gateway (default region; subscription header may
  // pin a specific apigw subdomain via the dynamic relay rules below,
  // but routing the whole apigw zone DIRECT keeps any region working).
  'DOMAIN-SUFFIX,apigw.yandexcloud.net,DIRECT',
];

class ParazitXMihomoOrchestrator {
  ParazitXMihomoOrchestrator._();

  /// Mutate [config] to inject the ParazitX bridge when [bridgeInfo] is
  /// non-null. Returns the underlying [MihomoPatchResult] for diagnostic
  /// callers, or `null` when no bridge is active.
  ///
  /// When [bridgeInfo] is provided here it is used verbatim. When it is
  /// omitted, the orchestrator falls back to [ParazitXManager.bridgeInfo]
  /// — which is the production path. Tests should pass [bridgeInfo]
  /// explicitly so they don't depend on the static singleton.
  ///
  /// [profile] is the active Profile if any; consulted for
  /// subscription-derived dynamic DIRECT rules (callfactory backends and
  /// signaling-relay hosts). When `null`, only the static rule set is
  /// applied. Tests should pass `null` and provide [extraDirectRules]
  /// explicitly when they want to assert behavior with dynamic content.
  ///
  /// [extraDirectRules] is appended (deduplicated) to the computed
  /// rule set — primarily a test-injection seam.
  ///
  /// [rulesKey] selects the map key under which mihomo rules live.
  /// Production callers go through `state.dart::patchRawConfig` which
  /// renames `rules` → `rule` (singular) before this orchestrator runs,
  /// so the production value is `'rule'`. Tests using a fresh config
  /// shape default to `'rules'`.
  static MihomoPatchResult? applyToConfig(
    Map<String, dynamic> config, {
    ParazitXBridgeInfo? bridgeInfo,
    bool useManagerFallback = false,
    Profile? profile,
    bool useProfileFallback = false,
    List<String> extraDirectRules = const <String>[],
    String rulesKey = 'rules',
  }) {
    final info = bridgeInfo ??
        (useManagerFallback ? ParazitXManager.bridgeInfo : null);
    if (info == null) return null;

    final activeProfile =
        profile ?? (useProfileFallback ? globalState.config.currentProfile : null);

    final directRules = _buildDirectRules(activeProfile, extraDirectRules);

    final result = MihomoDialerProxyPatcher.patch(
      config,
      bridgePort: info.port,
      bridgeServer: info.host,
      username: info.username.isEmpty ? null : info.username,
      password: info.password.isEmpty ? null : info.password,
      addToGroups: const [_kDefaultBridgeGroup],
      directRules: directRules,
      rulesKey: rulesKey,
    );

    // Single-shot log per patch invocation. No credentials are involved
    // (the orchestrator never has them — see Task 3 notepad).
    developer.log(
      '[Mihomo][config] ParazitX bridge injected '
      'host=${info.host} port=${info.port} '
      'added=${result.bridgeAdded} updated=${result.bridgeUpdated} '
      'patched=${result.patchedCount} skipped=${result.skippedCount} '
      'directRules=${result.directRulesAdded}/${directRules.length}',
      name: 'ParazitX',
    );
    LogBuffer.instance.add(
      '[Mihomo][config] ParazitX bridge injected '
      'host=${info.host} port=${info.port} '
      'directRules=${result.directRulesAdded}/${directRules.length}',
    );

    return result;
  }

  /// Compose the DIRECT rule list for self-loop protection.
  ///
  /// Layers, in priority order:
  ///   1. Static well-known rules ([_kStaticDirectRules]).
  ///   2. Dynamic rules derived from the active subscription's
  ///      `dropweb-parazitx-servers` header (callfactory `host:port`
  ///      entries, formatted as IP-CIDR/32 + DOMAIN as appropriate).
  ///   3. Dynamic rules derived from the active subscription's
  ///      `dropweb-parazitx-relays` header (HTTPS relay hostnames →
  ///      DOMAIN rule each).
  ///   4. Caller-supplied [extras] (test injection point).
  ///
  /// Output is deduplicated while preserving first-seen order. The
  /// patcher itself is also idempotent against existing duplicates in
  /// the rule list, but de-duping here keeps logs tidy.
  static List<String> _buildDirectRules(
    Profile? profile,
    List<String> extras,
  ) {
    final out = <String>[];
    final seen = <String>{};

    void addRule(String r) {
      final trimmed = r.trim();
      if (trimmed.isEmpty) return;
      if (seen.add(trimmed)) out.add(trimmed);
    }

    for (final r in _kStaticDirectRules) {
      addRule(r);
    }

    if (profile != null) {
      // Servers header → IP-CIDR for plain IPv4, DOMAIN(-SUFFIX) for
      // hostnames. An entry like '64.188.66.103:3478' yields
      // 'IP-CIDR,64.188.66.103/32,DIRECT,no-resolve'. A hostname entry
      // like 'cf.example.com:443' yields
      // 'DOMAIN,cf.example.com,DIRECT'.
      final serversRaw = profile.providerHeaders[_kServersHeaderName];
      if (serversRaw != null && serversRaw.isNotEmpty) {
        for (final part in serversRaw.split(',')) {
          final trimmed = part.trim();
          if (trimmed.isEmpty) continue;
          final hostPort = _splitHostPort(trimmed);
          if (hostPort == null) continue;
          final host = hostPort.$1;
          if (_looksLikeIpv4(host)) {
            addRule('IP-CIDR,$host/32,DIRECT,no-resolve');
          } else {
            addRule('DOMAIN,$host,DIRECT');
          }
        }
      }

      // Relays header → DOMAIN rule per parsed HTTPS host.
      final relaysRaw = profile.providerHeaders[_kRelaysHeaderName];
      if (relaysRaw != null && relaysRaw.isNotEmpty) {
        for (final part in relaysRaw.split(',')) {
          final trimmed = part.trim();
          if (trimmed.isEmpty) continue;
          final uri = Uri.tryParse(trimmed);
          if (uri == null || uri.host.isEmpty) continue;
          if (_looksLikeIpv4(uri.host)) {
            addRule('IP-CIDR,${uri.host}/32,DIRECT,no-resolve');
          } else {
            addRule('DOMAIN,${uri.host},DIRECT');
          }
        }
      }
    }

    for (final r in extras) {
      addRule(r);
    }

    return List.unmodifiable(out);
  }

  /// Split `host:port` (or bare `host`) into a `(host, port?)` tuple.
  /// Returns null on malformed inputs. IPv6 literals (`[::1]:443`) are
  /// not currently supported by ParazitX subscriptions; bracketed IPv6
  /// strings are rejected by returning null so we don't emit a broken
  /// rule.
  static (String, int?)? _splitHostPort(String input) {
    if (input.isEmpty) return null;
    if (input.startsWith('[')) return null; // IPv6 literal, unsupported.
    final colon = input.lastIndexOf(':');
    if (colon < 0) return (input, null);
    final host = input.substring(0, colon).trim();
    if (host.isEmpty) return null;
    final portStr = input.substring(colon + 1).trim();
    final port = int.tryParse(portStr);
    if (port == null) return (input, null); // Treat as bare host.
    return (host, port);
  }

  /// Cheap IPv4 detector — avoids a full RegExp by checking dotted-quad
  /// digit ranges. Good enough for subscription-supplied callfactory
  /// endpoints; non-matches fall through to DOMAIN rules which mihomo
  /// will resolve through DNS.
  static bool _looksLikeIpv4(String s) {
    final parts = s.split('.');
    if (parts.length != 4) return false;
    for (final p in parts) {
      if (p.isEmpty || p.length > 3) return false;
      final n = int.tryParse(p);
      if (n == null || n < 0 || n > 255) return false;
    }
    return true;
  }
}
