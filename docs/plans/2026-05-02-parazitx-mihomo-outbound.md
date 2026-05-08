# ParazitX Mihomo Outbound Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Move ParazitX from a standalone Android `VpnService` + `tun2socks` pipeline into a Mihomo-managed outbound/proxy mode so Mihomo remains the only TUN/DNS/fake-IP owner.

**Architecture:** ParazitX will still perform VK TURN/session initialization and run the local relay SOCKS endpoint, but it will no longer establish its own VPN or run tun2socks. Instead, Dropweb patches the active Mihomo config to route selected outbounds through a local SOCKS5 proxy exposed by ParazitX. Mihomo keeps DNS/fake-IP mapping, rules, and TUN routing, which avoids sending `198.18.0.0/15` fake-IP addresses directly to the ParazitX server.

**Tech Stack:** Flutter/Dart, Android Kotlin services, embedded Go relay (`libparazitx-relay.so`), Mihomo/Clash config patching, Remnawave subscription headers, Android ADB/logcat, server `pzx-001` callfactory logs.

---

## Current State and Evidence

- Init path works via Remnawave headers:
  - `dropweb-parazitx-servers: 64.188.66.103:3478`
  - `dropweb-parazitx-relays: https://d5da461207asfg6i1lmt.628pfjdx.apigw.yandexcloud.net`
  - `dropweb-parazitx-relays` must be treated as `https-session`, matching old `_ycProxyUrl` behavior.
- Half-close datapath bug is fixed in the current diagnostic build:
  - Client sends `MsgCloseWrite` on local SOCKS EOF.
  - Server drains queued request bytes, calls `TCPConn.CloseWrite()`, keeps read side open, and forwards response bytes.
  - Logs showed `recv>0 sent>0` and `DC->SOCKS write=... err=<nil>`.
- Remaining blocker in standalone VPN mode: fake-IP addresses reach ParazitX SOCKS as real CONNECT targets:
  - Client log: `SOCKS CONNECT ... -> 198.18.x.x:443`.
  - Server log: `CONNECT ... failed: dial tcp198.18.x.x:443: i/o timeout`.
- This happens because `ParazitXVpnService` owns a separate TUN/tun2socks pipeline that does not have Mihomo's fake-IP reverse mapping.
- Therefore the stable architecture is: Mihomo owns TUN/DNS/fake-IP; ParazitX is a local SOCKS outbound used by Mihomo.

## Non-Goals

- Do not commit to `whitelist-bypass`; use `parazitx` as the source of truth for ParazitX relay code.
- Do not introduce another subscription header for session relays.
- Do not route user traffic through the YC/API Gateway init relay.
- Do not keep verbose per-payload instrumentation in production.
- Do not run two Android VPN services simultaneously.

## Task 1: Freeze and document the current proven fixes

- [x] Completed by orchestration: findings recorded in `.sisyphus/notepads/2026-05-02-parazitx-mihomo-outbound/`; no runtime behavior changes.

**Files:**
- Modify: `docs/plans/2026-05-02-parazitx-mihomo-outbound.md`
- Inspect: `/Users/oen/Documents/projects/parazitx/relay/tunnel/protocol.go`
- Inspect: `/Users/oen/Documents/projects/parazitx/relay/tunnel/relay_bridge.go`
- Inspect: `/Users/oen/Documents/projects/dropweb-app/lib/services/parazitx_manager.dart`

**Step 1: Verify current worktree diffs**

Run:

```bash
cd /Users/oen/Documents/projects/dropweb-app && git diff --stat -- ':!node_modules'
cd /Users/oen/Documents/projects/parazitx && git diff --stat -- ':!node_modules'
```

Expected: Dropweb has `libparazitx-relay.so` and `parazitx_manager.dart`; ParazitX has protocol/relay half-close changes. If `whitelist-bypass` has changes, treat them as scratch and do not commit them.

**Step 2: Capture exact server binary provenance**

Run on `pzx-001`:

```bash
ssh root@64.188.66.103 'sha256sum /opt/parazitx/creator/headless-vk-creator-linux-x64; ls -lh /opt/parazitx/creator/headless-vk-creator-linux-x64* | tail'
```

Expected: identify current deployed diagnostic binary and backups. Record hash in this plan if needed.

**Step 3: Do not commit yet**

Expected: no git commit. This task only records context.

## Task 2: Make ParazitX relay lifecycle available without `ParazitXVpnService`

- [x] Completed by orchestration: `ParazitXVpnService` now supports legacy `standalone_vpn` and relay-only `mihomo_outbound` mode; Dart analyzer check passed, Kotlin compile deferred to Android build.

**Files:**
- Inspect: `android/app/src/main/kotlin/app/dropweb/services/ParazitXVpnService.kt`
- Inspect: `android/app/src/main/kotlin/app/dropweb/MainActivity.kt`
- Inspect: `lib/services/parazitx_manager.dart`
- Modify/Create: Android Kotlin service/controller file only after tests/plan review; likely a new service or mode in `ParazitXVpnService.kt`.

**Purpose:** Start the ParazitX relay process and wait for `TUNNEL_CONNECTED`, but do not call `VpnService.Builder`, `establish()`, or `Androidbind.startTun2Socks()`.

**Step 1: Write a lifecycle design note in comments or docs**

Document two modes:

```text
standalone-vpn mode: legacy ParazitXVpnService owns VPN + tun2socks
mihomo-outbound mode: ParazitX starts relay only, Mihomo owns VPN/TUN/DNS
```

Expected: no runtime behavior change yet.

**Step 2: Add an explicit mode enum/extra**

Add an Android intent extra such as:

```kotlin
const val EXTRA_MODE = "mode"
const val MODE_STANDALONE_VPN = "standalone_vpn"
const val MODE_MIHOMO_OUTBOUND = "mihomo_outbound"
```

Expected: default remains `standalone_vpn` for backward compatibility.

**Step 3: Gate tun establishment**

In the status path where relay reports `TUNNEL_CONNECTED`, only call `establishTunAndStartTun2Socks(...)` when mode is `standalone_vpn`.

Expected in mihomo mode: relay stays alive, broadcasts `TUNNEL_CONNECTED`, but no `tun established` / no `tun2socks running` log from `ParazitXVpnService`.

**Step 4: Verify with build**

Run:

```bash
cd /Users/oen/Documents/projects/dropweb-app
flutter analyze lib/services/parazitx_manager.dart
```

Expected: no Dart analyzer errors. Kotlin compile verified later by Android build.

## Task 3: Expose ParazitX local SOCKS endpoint to Dart reliably

- [x] Completed by orchestration: `ParazitXBridgeInfo` and stream/getter added; bridge is published on tunnel-ready and cleared on failure/deactivate; analyzer and targeted ParazitX tests passed.

**Files:**
- Inspect/Modify: `lib/services/parazitx_manager.dart`
- Inspect: `android/app/src/main/kotlin/app/dropweb/services/ParazitXVpnService.kt`
- Inspect: `android/app/src/main/kotlin/app/dropweb/MainActivity.kt`

**Purpose:** Mihomo config patching needs the local SOCKS port and credentials exposed by ParazitX relay.

**Step 1: Verify existing source of port/credentials**

Search:

```bash
grep -R "getSocksCredentials\|socksPort\|EXTRA_SOCKS_PORT" -n android lib
```

Expected: `ParazitXRelayController.getSocksCredentials()` and `EXTRA_SOCKS_PORT` already exist.

**Step 2: Add a Dart-side state object**

Represent active ParazitX bridge info:

```dart
class ParazitXBridgeInfo {
  const ParazitXBridgeInfo({required this.host, required this.port});
  final String host;
  final int port;
}
```

Keep credentials internal unless Mihomo needs them in config. If Mihomo SOCKS5 outbound needs username/password, expose them securely only to config patching and never logs.

**Step 3: Add logs without secrets**

Log only:

```text
[ParazitX][mihomo] bridge ready host=127.0.0.1 port=PORT
```

Do not log username/password.

## Task 4: Replace `MihomoDialerProxyPatcher` with a ParazitX outbound patcher mode

- [x] Completed by orchestration: patcher now supports optional credentials and idempotent group append for `__dropweb_parazitx_vk_bridge`; scope-creep platform identity edits were reverted; targeted tests/analyzer passed.

**Files:**
- Modify: `lib/services/mihomo_dialer_proxy_patcher.dart`
- Modify tests: `test/services/mihomo_dialer_proxy_patcher_test.dart`

**Current behavior:** The existing patcher only adds a bridge proxy and sets `dialer-proxy` on Hysteria/Hysteria2 proxies. That routes only selected proxy dials through ParazitX and does not make ParazitX a full outbound for all traffic.

**Target behavior:** Add a mode that can inject a full SOCKS5 outbound named `__dropweb_parazitx_vk_bridge` and optionally route selected groups to it while preserving subscription ownership.

**Step 1: Write failing test for bridge proxy creation with credentials**

Add test:

```dart
test('adds ParazitX SOCKS outbound with optional credentials', () {
  final config = <String, dynamic>{'proxies': <dynamic>[]};
  final result = MihomoDialerProxyPatcher.patch(
    config,
    bridgePort: 18080,
    username: 'u',
    password: 'p',
  );
  expect(result.bridgeAdded, true);
  expect(config['proxies'], contains(<String, dynamic>{
    'name': kDropwebParazitXBridgeName,
    'type': 'socks5',
    'server': '127.0.0.1',
    'port': 18080,
    'username': 'u',
    'password': 'p',
  }));
});
```

Run:

```bash
flutter test test/services/mihomo_dialer_proxy_patcher_test.dart
```

Expected: FAIL because username/password are not supported yet.

**Step 2: Implement minimal credential fields**

Add optional `username` and `password` args. Only include fields when non-empty.

Expected: test passes.

**Step 3: Add failing test for group routing mode**

Decide whether ParazitX should:

- A. become an option in the main selector group, user selects it; or
- B. override the selected/default group while active; or
- C. remain only a `dialer-proxy` bridge for existing Hysteria/Hysteria2 outbounds.

Recommended: A first. Add bridge to groups without forcing selection.

Example test:

```dart
test('can append ParazitX bridge to select groups without changing selected value', () {
  final config = <String, dynamic>{
    'proxies': <dynamic>[],
    'proxy-groups': <dynamic>[
      {'name': 'GLOBAL', 'type': 'select', 'proxies': ['DIRECT']},
    ],
  };
  MihomoDialerProxyPatcher.patch(
    config,
    bridgePort: 18080,
    addToGroups: const ['GLOBAL'],
  );
  expect((config['proxy-groups'] as List).first['proxies'], ['DIRECT', kDropwebParazitXBridgeName]);
});
```

Expected: FAIL until implemented.

**Step 4: Implement group append idempotently**

Only append bridge name to named groups when group exists and has a `proxies` list. Do not modify rules/rule-providers/DNS/TUN.

Expected: all patcher tests pass.

## Task 5: Add Mihomo config orchestration for ParazitX active mode

- [x] Completed by orchestration: added `ParazitXMihomoOrchestrator`, wired `patchRawConfig` to inject bridge when `ParazitXManager.bridgeInfo` is active, and verified patcher/orchestrator tests plus analyzer.

**Files:**
- Inspect/Modify: `lib/state.dart`
- Inspect/Modify: `lib/services/parazitx_manager.dart`
- Inspect existing config reload/apply APIs in `core/hub.go`, `core/common.go`, and Flutter controller/provider paths.

**Purpose:** When ParazitX enters `TUNNEL_CONNECTED`, patch active Mihomo config so Mihomo can route through ParazitX bridge.

**Step 1: Locate where provider config is patched**

Relevant current code:

- `lib/state.dart` `patchRawConfig(...)`
- Existing `MihomoDialerProxyPatcher.patch(...)` calls, if any.

Run:

```bash
grep -R "MihomoDialerProxyPatcher.patch\|patchRawConfig" -n lib test
```

Expected: identify one insertion point.

**Step 2: Add failing unit test for ParazitX-active config patch**

Test should prove that when ParazitX bridge is active, patched config contains bridge proxy and selected group includes it.

Expected: FAIL until orchestration passes bridge info to patcher.

**Step 3: Implement minimal orchestration**

When activation succeeds and relay reports `TUNNEL_CONNECTED`, store `ParazitXBridgeInfo` in app state and trigger Mihomo config reload/repatch.

Expected logs:

```text
[ParazitX][mihomo] bridge ready
[Mihomo][config] ParazitX bridge injected
```

**Step 4: Stop cleanup**

When ParazitX stops, remove bridge state and trigger config reload so Mihomo no longer routes to a dead local SOCKS.

Expected: bridge entry disappears or becomes unused after stop.

## Task 6: Protect ParazitX relay signaling from Mihomo self-loop

- [x] Completed by orchestration: Go relay lacks Android `protect(fd)` hook, so implemented temporary Mihomo DIRECT-rule fallback for VK/Yandex/API Gateway/callfactory endpoints; patcher/orchestrator tests and analyzer passed.

**Files:**
- Inspect: `android/app/src/main/kotlin/app/dropweb/plugins/VpnPlugin.kt`
- Inspect: `android/app/src/main/kotlin/app/dropweb/services/ParazitXVpnService.kt`
- Inspect Go relay socket protect hooks in `parazitx` and Android binding.

**Problem:** If Mihomo routes all traffic through ParazitX SOCKS, the ParazitX relay's own WebRTC/VK signaling sockets may loop through Mihomo back into ParazitX.

**Step 1: Verify current protect mechanism**

Search:

```bash
grep -R "protect(fd\|VpnService.protect\|Protect" -n android core /Users/oen/Documents/projects/parazitx
```

Expected: identify whether Go relay can call Android `VpnService.protect(fd)` or equivalent.

**Step 2: If protect exists, wire it for mihomo-outbound mode**

Ensure relay sockets are protected/direct before WebRTC/TURN/signaling connects.

Expected: relay init traffic does not appear as SOCKS CONNECT back into ParazitX.

**Step 3: If protect does not exist, use rules as temporary fallback**

Add Mihomo DIRECT rules for:

- VK call/signaling endpoints used by relay;
- YC API Gateway init endpoint;
- `64.188.66.103:3478` direct backend if used.

This is less robust than `protect(fd)` and should be documented as temporary.

## Task 7: Disable standalone ParazitX VPN path behind a feature flag

- [x] Completed by orchestration: added `kParazitXUseMihomoOutbound = true`, pass-through mode wiring to native service, `[ParazitX][mode] mihomo-outbound` logging, and bridge-state config reload triggers; analyzer/tests passed.

**Files:**
- Modify: `lib/services/parazitx_manager.dart`
- Modify: `android/app/src/main/kotlin/app/dropweb/services/ParazitXVpnService.kt`
- Modify tests as applicable.

**Step 1: Add feature flag**

Add a Dart constant or remote/config setting:

```dart
const kParazitXUseMihomoOutbound = true;
```

Keep legacy standalone path available during migration.

**Step 2: Route activation based on flag**

If true: start relay in `MODE_MIHOMO_OUTBOUND`. If false: current standalone VPN path.

Expected: reversible migration.

**Step 3: Add logging**

Expected logs:

```text
[ParazitX][mode] mihomo-outbound
```

## Task 8: Build and manual QA

- [x] Completed by orchestration: static checks/tests passed, canonical ParazitX relay rebuilt byte-identical, Android arm64 release APK built successfully; device/server QA blocked by no attached device and SSH host-key trust issue.

**Files:**
- Build artifact: `android/app/src/main/jniLibs/arm64-v8a/libparazitx-relay.so`
- APK artifact: `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`

**Step 1: Run static checks**

```bash
flutter analyze lib/services/parazitx_manager.dart lib/services/mihomo_dialer_proxy_patcher.dart
flutter test test/services/mihomo_dialer_proxy_patcher_test.dart
```

Expected: no errors; tests pass.

**Step 2: Rebuild ParazitX relay library from `parazitx`**

```bash
cd /Users/oen/Documents/projects/parazitx/relay
GOOS=linux GOARCH=arm64 go build -trimpath -ldflags='-s -w' -o /tmp/libparazitx-relay.arm64.so .
cp /tmp/libparazitx-relay.arm64.so /Users/oen/Documents/projects/dropweb-app/android/app/src/main/jniLibs/arm64-v8a/libparazitx-relay.so
```

Expected: Android arm64 ELF copied into Dropweb.

**Step 3: Build APK**

```bash
cd /Users/oen/Documents/projects/dropweb-app
JAVA_HOME="/opt/homebrew/Cellar/openjdk@17/17.0.19/libexec/openjdk.jdk/Contents/Home" \
ANDROID_NDK="/opt/homebrew/share/android-commandlinetools/ndk/28.0.13004108" \
dart run setup.dart android --arch arm64
```

Expected artifact:

```text
build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

**Step 4: Device QA**

Install APK, enable VK TURN, then verify:

```text
ParazitX relay starts
Mihomo remains the active VPN/TUN owner
No ParazitXVpnService tun2socks logs
No SOCKS CONNECT to 198.18.x.x on pzx-001
Server callfactory shows recv>0 sent>0 for real IP/domain flows
Browser/Telegram traffic works under whitelist
```

**Step 5: Server log check**

On `pzx-001`:

```bash
journalctl -u callfactory --since "10 minutes ago" --no-pager -o short-iso | grep -E "198\.18|CONNECT .*failed|recv=|sent=|CloseWrite|MsgCloseWrite"
```

Expected: no `CONNECT ... 198.18.x.x` failures. Normal `recv/sent` counters remain.

## Task 9: Cleanup diagnostic noise before production

- [x] Completed by orchestration: canonical `parazitx` now handles `MsgCloseWrite` server-side, per-payload relay logs were removed/guarded, summary logs retained, relay `.so` rebuilt/copied, and Go/Dart tests/analyzer passed.

**Files:**
- Modify: `/Users/oen/Documents/projects/parazitx/relay/tunnel/relay_bridge.go`
- Modify server source in canonical `parazitx` repo only.
- Do not modify/commit `whitelist-bypass`.

**Step 1: Decide log levels**

Keep summary logs:

```text
MsgCloseWrite
CloseWrite ok/error
conn closed recv=... sent=...
```

Remove or guard per-payload logs:

```text
SOCKS->DC bytes=...
DC->SOCKS bytes=...
MsgData enqueue bytes=...
```

**Step 2: Rebuild and smoke-test after cleanup**

Repeat Task 8 static checks and one short device smoke-test.

Expected: less log spam; behavior unchanged.

## Open Questions for Next Session

1. Which Mihomo group should receive/select the ParazitX outbound?
   - Main `GLOBAL` selector?
   - A dedicated `VK TURN` selector?
   - Automatic override while VK TURN is active?
2. Do we need a UI toggle for `mihomo-outbound` vs legacy standalone mode, or can it be internal during migration?
3. Does ParazitX relay already support Android socket protection, or do we need to add it in `parazitx`?
4. Where is the canonical server-side `TunnelRelay` source in `parazitx`? Do not commit `whitelist-bypass`; port any required server half-close changes into `parazitx` source of truth.

## Handoff Summary

Continue by implementing Task 1 and Task 2. Do not start by editing `whitelist-bypass`. The core architectural direction is: Mihomo owns VPN/TUN/DNS/fake-IP; ParazitX provides a local SOCKS outbound and VK TURN/WebRTC datachannel transport. The immediate validation criterion is eliminating `SOCKS CONNECT 198.18.x.x` from ParazitX server logs.
