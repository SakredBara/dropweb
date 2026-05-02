import 'package:flutter/services.dart';

/// Activation mode flag for the ParazitX path.
///
/// When `true` (default after Task 7 of the 2026-05-02 plan), the Dart
/// activation path requests the native `ParazitXVpnService` in
/// [kParazitXModeMihomoOutbound] — relay-only lifecycle. Mihomo's own
/// `DropwebVpnService` owns TUN/DNS/fake-IP and routes through the
/// relay's local SOCKS5 listener (the "bridge") as a normal outbound.
///
/// When `false`, the legacy [kParazitXModeStandaloneVpn] path is used:
/// ParazitX establishes its own VpnService, builds the tun, and runs
/// tun2socks. Kept reversible by flipping this constant — useful for
/// fast bisection if a regression is suspected post-Wave-2.
///
/// This is a compile-time constant on purpose: mode switching at
/// runtime is out of scope; flipping requires a rebuild + reinstall.
const bool kParazitXUseMihomoOutbound = true;

/// Mirror of the Kotlin-side `MODE_STANDALONE_VPN` constant in
/// `ParazitXVpnService.companion`. Kept as a plain Dart string so the
/// feature-flag wiring stays purely in Dart space.
const String kParazitXModeStandaloneVpn = 'standalone_vpn';

/// Mirror of Kotlin-side `MODE_MIHOMO_OUTBOUND`. See
/// [kParazitXUseMihomoOutbound] for semantics. Same string contract;
/// the native handler validates it explicitly and falls back to
/// standalone on unknown / missing input.
const String kParazitXModeMihomoOutbound = 'mihomo_outbound';

class ParazitXVpnPlugin {
  static const _channel = MethodChannel('app.dropweb/parazitx_vpn');

  /// Conservative default MTU for the ParazitX tun. The dataplane is
  /// effectively WebRTC DataChannel/TURN, whose path MTU is closer to
  /// 1200–1280 than to a wired Ethernet 1500. Using 1500 caused IP
  /// fragmentation and silent reassembly drops for large UDP/TCP
  /// segments. 1280 is the IPv6 minimum MTU and a known-safe baseline
  /// for tunneled WebRTC paths.
  static const int defaultMtu = 1280;

  /// Default activation mode resolved from the [kParazitXUseMihomoOutbound]
  /// feature flag. Callers may still override it by passing `mode` to
  /// [start] directly (used by tests / future runtime selectors).
  static String get defaultMode => kParazitXUseMihomoOutbound
      ? kParazitXModeMihomoOutbound
      : kParazitXModeStandaloneVpn;

  /// Starts the ParazitX VpnService. The service (in `:parazitx` process)
  /// owns the relay pipeline. In [kParazitXModeStandaloneVpn] mode it
  /// also builds the tun + tun2socks. In [kParazitXModeMihomoOutbound]
  /// mode it stops at relay startup; Mihomo's `DropwebVpnService` owns
  /// the tun and routes through the relay's local SOCKS5 listener.
  ///
  /// [mtu] sets both the VpnService.Builder MTU and the value passed to
  /// `Androidbind.startTun2Socks` (standalone mode only) so the kernel
  /// and tun2socks agree. Defaults to [defaultMtu] (1280); the native
  /// layer additionally clamps to a sane range and falls back to 1280
  /// on out-of-range input.
  ///
  /// `mode` selects the native operating mode. Defaults to [defaultMode]
  /// (driven by [kParazitXUseMihomoOutbound]). Unknown values fall back
  /// to standalone on the Kotlin side; passing an explicit value here
  /// avoids that fallback.
  ///
  /// `socksUser` / `socksPass` override the relay's per-process random
  /// credentials. Required for the Mihomo-outbound mode so the Dart
  /// side can publish the same credentials on `ParazitXBridgeInfo` and
  /// Mihomo's bridge proxy can authenticate against the relay's SOCKS5
  /// listener. When omitted, the relay generates random creds itself
  /// (legacy standalone-VPN path uses tun2socks which reads them via
  /// `ParazitXRelayController.getSocksCredentials()` in-process).
  static Future<void> start({
    required String joinLink,
    int socksPort = 1080,
    int mtu = defaultMtu,
    String? mode,
    String? socksUser,
    String? socksPass,
  }) async {
    await _channel.invokeMethod<void>('start', {
      'joinLink': joinLink,
      'socksPort': socksPort,
      'mtu': mtu,
      'mode': mode ?? defaultMode,
      if (socksUser != null) 'socksUser': socksUser,
      if (socksPass != null) 'socksPass': socksPass,
    });
  }

  static Future<void> stop() async {
    await _channel.invokeMethod<void>('stop');
  }

  static Future<bool> isRunning() async {
    final res = await _channel.invokeMethod<bool>('isRunning');
    return res ?? false;
  }
}
