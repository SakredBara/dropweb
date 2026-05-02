/// Patches a decoded Mihomo (clash-meta) configuration so that all
/// Hysteria/Hysteria2 outbound proxies dial through a local SOCKS5 bridge
/// exposed by the ParazitX VPN service (callfactory → vk-tunnel →
/// hysteria2-vk pipeline).
///
/// Design constraints (from product architecture):
///
/// * Subscriptions (Remnawave) remain the source of truth for proxy
///   groups, rules, and rule-providers. We **never** reshape them.
/// * Only the bridge proxy entry is appended, and only Hysteria/Hysteria2
///   proxies receive the `dialer-proxy` field. Other proxy types are
///   untouched.
/// * The patcher is idempotent: applying it twice with a different bridge
///   port updates the existing entry instead of duplicating it.
/// * If a Hysteria/Hysteria2 proxy already has a non-Dropweb
///   `dialer-proxy`, we treat it as a user override and leave it alone,
///   reporting it as skipped.
///
/// The patcher is a pure function over `Map<String, dynamic>`; no IO,
/// no platform calls, no UI. Higher-level orchestration (when to patch,
/// where to get the bridge port) lives in `ParazitXManager`.
library;

/// Stable name of the local SOCKS5 bridge proxy injected into the
/// `proxies` array. The leading `__` makes it visually distinct from
/// user-named proxies and keeps it sorted at the bottom of most UIs.
const kDropwebParazitXBridgeName = '__dropweb_parazitx_vk_bridge';

/// Default loopback address for the bridge proxy. Overridable via
/// [MihomoDialerProxyPatcher.patch]'s `bridgeServer` argument for tests
/// or non-standard deployments.
const kDropwebParazitXBridgeServer = '127.0.0.1';

/// Mihomo proxy types that must be routed through the bridge.
const _patchableTypes = <String>{'hysteria', 'hysteria2'};

/// Why a particular proxy was skipped during patching.
enum SkipReason {
  /// Proxy already has a `dialer-proxy` set to something other than the
  /// Dropweb bridge — treated as a user override.
  userDialerProxy,
}

/// One skipped proxy entry, recorded for diagnostics/UI.
class SkippedProxy {
  const SkippedProxy({required this.name, required this.reason});

  final String name;
  final SkipReason reason;
}

/// Result of [MihomoDialerProxyPatcher.patch].
class MihomoPatchResult {
  const MihomoPatchResult({
    required this.bridgeAdded,
    required this.bridgeUpdated,
    required this.patchedCount,
    required this.skipped,
    required this.directRulesAdded,
  });

  /// `true` when a new bridge proxy entry was inserted into `proxies`.
  /// Mutually exclusive with [bridgeUpdated].
  final bool bridgeAdded;

  /// `true` when an existing Dropweb bridge entry was updated in place
  /// (e.g. port changed). Mutually exclusive with [bridgeAdded].
  final bool bridgeUpdated;

  /// Number of Hysteria/Hysteria2 proxies that received a fresh
  /// `dialer-proxy` value pointing at the bridge.
  final int patchedCount;

  /// Proxies that were intentionally not patched, with reasons.
  final List<SkippedProxy> skipped;

  /// Number of DIRECT-rule strings prepended to the `rules` list during
  /// this patch invocation. Existing duplicates (already present in
  /// `rules`) are not counted.
  final int directRulesAdded;

  int get skippedCount => skipped.length;
}

/// Stateless utility class.
class MihomoDialerProxyPatcher {
  MihomoDialerProxyPatcher._();

  /// Mutates [config] in place. Returns a [MihomoPatchResult] summarising
  /// the changes for logging/diagnostics.
  ///
  /// The function does NOT touch `proxy-groups`, `rules`, `rule-providers`,
  /// `dns`, or `tun`. It only edits `proxies` and the entries within it.
  static MihomoPatchResult patch(
    Map<String, dynamic> config, {
    required int bridgePort,
    String bridgeServer = kDropwebParazitXBridgeServer,
    String? username,
    String? password,
    List<String> addToGroups = const <String>[],
    List<String> directRules = const <String>[],
    String rulesKey = 'rules',
  }) {
    // Ensure the proxies list exists and is mutable. Mihomo allows the
    // field to be absent on minimal configs.
    final rawProxies = config['proxies'];
    final List<dynamic> proxies;
    if (rawProxies is List) {
      proxies = rawProxies;
    } else {
      proxies = <dynamic>[];
      config['proxies'] = proxies;
    }

    // Normalise credentials: only attach when both fields are non-empty.
    // Mihomo's basic socks5 outbound treats `username`/`password` as
    // optional plain fields; sending empty strings would make it attempt
    // RFC1929 auth with empty creds, which the relay would reject.
    final hasCreds = username != null &&
        username.isNotEmpty &&
        password != null &&
        password.isNotEmpty;

    // Step 1: bridge entry (insert or update in place).
    var bridgeAdded = false;
    var bridgeUpdated = false;
    Map<String, dynamic>? existingBridge;
    for (final p in proxies) {
      if (p is Map && p['name'] == kDropwebParazitXBridgeName) {
        existingBridge = p.cast<String, dynamic>();
        break;
      }
    }
    if (existingBridge == null) {
      final fresh = <String, dynamic>{
        'name': kDropwebParazitXBridgeName,
        'type': 'socks5',
        'server': bridgeServer,
        'port': bridgePort,
      };
      if (hasCreds) {
        fresh['username'] = username;
        fresh['password'] = password;
      }
      proxies.add(fresh);
      bridgeAdded = true;
    } else {
      final prevUsername = existingBridge['username'];
      final prevPassword = existingBridge['password'];
      final hadDifferentValues = existingBridge['type'] != 'socks5' ||
          existingBridge['server'] != bridgeServer ||
          existingBridge['port'] != bridgePort ||
          (hasCreds
              ? (prevUsername != username || prevPassword != password)
              : (prevUsername != null || prevPassword != null));
      existingBridge['type'] = 'socks5';
      existingBridge['server'] = bridgeServer;
      existingBridge['port'] = bridgePort;
      if (hasCreds) {
        existingBridge['username'] = username;
        existingBridge['password'] = password;
      } else {
        existingBridge
          ..remove('username')
          ..remove('password');
      }
      bridgeUpdated = hadDifferentValues;
    }

    // Step 2: walk Hysteria/Hysteria2 proxies and attach dialer-proxy.
    var patchedCount = 0;
    final skipped = <SkippedProxy>[];
    for (final p in proxies) {
      if (p is! Map) continue;
      if (p['name'] == kDropwebParazitXBridgeName) continue;
      final type = p['type'];
      if (type is! String || !_patchableTypes.contains(type)) continue;

      final existingDialer = p['dialer-proxy'];
      if (existingDialer is String &&
          existingDialer.isNotEmpty &&
          existingDialer != kDropwebParazitXBridgeName) {
        // Respect user override.
        final name = p['name'];
        skipped.add(SkippedProxy(
          name: name is String ? name : '<unnamed>',
          reason: SkipReason.userDialerProxy,
        ));
        continue;
      }

      p['dialer-proxy'] = kDropwebParazitXBridgeName;
      patchedCount++;
    }

    // Step 3: prepend DIRECT rules (relay self-loop fallback).
    //
    // Contract:
    // * Each entry is a fully-formed Mihomo rule string (e.g.
    //   "DOMAIN-SUFFIX,vk.com,DIRECT" / "IP-CIDR,1.2.3.4/32,DIRECT,no-resolve").
    // * Rules are PREPENDED so they win over any catch-all `MATCH,...`
    //   that subscriptions place at the end of the list.
    // * Empty / whitespace-only entries are silently dropped — keeps the
    //   caller honest without crashing on a quirky input.
    // * Idempotent: an entry already present anywhere in the existing
    //   `rules` list is not re-added.
    // * Order of NEW entries among themselves is preserved (caller
    //   controls priority by ordering [directRules]).
    // * If `rules` is missing/non-list, we create it ONLY when there is
    //   at least one new rule to add — same ownership rule as for
    //   proxy-groups (no key invention without a real change).
    //
    // This is the temporary self-loop protection path documented in
    // the 2026-05-02 plan (Task 6 Step 3): when ParazitX serves as
    // Mihomo's outbound, mihomo would otherwise route the relay's own
    // signaling/init sockets through ParazitX SOCKS, creating a loop
    // back into the relay. DIRECT rules pin known endpoints (VK
    // signaling, YC API Gateway init, configured callfactory backends)
    // to the underlying network so the relay's own bootstrap can
    // bypass mihomo's TUN. This is less robust than `VpnService.protect(fd)`
    // because we have to enumerate endpoints — but the Go relay does
    // not (yet) expose Android socket protection, so this is the
    // available primitive.
    var directRulesAdded = 0;
    final cleanedDirect = directRules
        .where((r) => r.trim().isNotEmpty)
        .toList(growable: false);
    if (cleanedDirect.isNotEmpty) {
      final rawRules = config[rulesKey];
      final List<dynamic> rules;
      if (rawRules is List) {
        rules = rawRules;
      } else {
        rules = <dynamic>[];
        config[rulesKey] = rules;
      }
      final existing = rules.whereType<String>().toSet();
      var insertAt = 0;
      for (final r in cleanedDirect) {
        if (existing.contains(r)) continue;
        rules.insert(insertAt, r);
        existing.add(r);
        insertAt++;
        directRulesAdded++;
      }
    }

    // Step 4: append bridge name to selected proxy-groups (optional).
    //
    // Contract:
    // * Only groups named in [addToGroups] are touched.
    // * If the group does not exist, it is silently skipped — we never
    //   invent groups; subscription owns the proxy-group set.
    // * If the group exists but lacks a `proxies` list, we leave it
    //   alone (no key invention) — same ownership rule.
    // * Append is idempotent: if the bridge name is already present in
    //   the list, we do not add it again.
    // * `selected` / `default` / any other group field is preserved
    //   verbatim. We do NOT switch the active proxy.
    if (addToGroups.isNotEmpty) {
      final rawGroups = config['proxy-groups'];
      if (rawGroups is List) {
        final wanted = addToGroups.toSet();
        for (final g in rawGroups) {
          if (g is! Map) continue;
          final name = g['name'];
          if (name is! String || !wanted.contains(name)) continue;
          final groupProxies = g['proxies'];
          if (groupProxies is! List) continue;
          if (!groupProxies.contains(kDropwebParazitXBridgeName)) {
            groupProxies.add(kDropwebParazitXBridgeName);
          }
        }
      }
    }

    return MihomoPatchResult(
      bridgeAdded: bridgeAdded,
      bridgeUpdated: bridgeUpdated && !bridgeAdded,
      patchedCount: patchedCount,
      skipped: List.unmodifiable(skipped),
      directRulesAdded: directRulesAdded,
    );
  }
}
