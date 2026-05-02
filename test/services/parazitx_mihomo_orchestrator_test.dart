import 'package:dropweb/services/mihomo_dialer_proxy_patcher.dart';
import 'package:dropweb/services/parazitx_manager.dart';
import 'package:dropweb/services/parazitx_mihomo_orchestrator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ParazitXMihomoOrchestrator.applyToConfig', () {
    test('injects bridge proxy and appends to GLOBAL when bridge active', () {
      final config = <String, dynamic>{
        'proxies': <dynamic>[],
        'proxy-groups': <dynamic>[
          <String, dynamic>{
            'name': 'GLOBAL',
            'type': 'select',
            'proxies': <String>['DIRECT'],
          },
        ],
      };
      const info = ParazitXBridgeInfo(host: '127.0.0.1', port: 18080);

      final result = ParazitXMihomoOrchestrator.applyToConfig(
        config,
        bridgeInfo: info,
      );

      expect(result, isNotNull);
      expect(result!.bridgeAdded, true);

      final proxies = (config['proxies'] as List).cast<Map<String, dynamic>>();
      final bridge = proxies.firstWhere(
        (p) => p['name'] == kDropwebParazitXBridgeName,
      );
      expect(bridge['type'], 'socks5');
      expect(bridge['server'], '127.0.0.1');
      expect(bridge['port'], 18080);

      final groups =
          (config['proxy-groups'] as List).cast<Map<String, dynamic>>();
      final global = groups.firstWhere((g) => g['name'] == 'GLOBAL');
      expect(global['proxies'], ['DIRECT', kDropwebParazitXBridgeName]);
    });

    test('does nothing when bridgeInfo is null', () {
      final config = <String, dynamic>{
        'proxies': <dynamic>[
          <String, dynamic>{
            'name': 'hy2',
            'type': 'hysteria2',
            'server': 'h.example.com',
            'port': 443,
          },
        ],
        'proxy-groups': <dynamic>[
          <String, dynamic>{
            'name': 'GLOBAL',
            'type': 'select',
            'proxies': <String>['DIRECT', 'hy2'],
          },
        ],
      };

      final result = ParazitXMihomoOrchestrator.applyToConfig(
        config,
        bridgeInfo: null,
      );

      expect(result, isNull);

      final proxies = (config['proxies'] as List).cast<Map<String, dynamic>>();
      final hasBridge =
          proxies.any((p) => p['name'] == kDropwebParazitXBridgeName);
      expect(hasBridge, false);
      // hysteria2 entry must NOT have dialer-proxy injected when bridge off.
      final hy = proxies.firstWhere((p) => p['name'] == 'hy2');
      expect(hy.containsKey('dialer-proxy'), false);

      final groups =
          (config['proxy-groups'] as List).cast<Map<String, dynamic>>();
      final global = groups.firstWhere((g) => g['name'] == 'GLOBAL');
      expect(global['proxies'], ['DIRECT', 'hy2']);
    });

    test(
        'skips GLOBAL group append when group is absent (subscription ownership preserved)',
        () {
      final config = <String, dynamic>{
        'proxies': <dynamic>[],
        'proxy-groups': <dynamic>[
          <String, dynamic>{
            'name': 'PROXY',
            'type': 'select',
            'proxies': <String>['DIRECT'],
          },
        ],
      };
      const info = ParazitXBridgeInfo(host: '127.0.0.1', port: 18080);

      ParazitXMihomoOrchestrator.applyToConfig(config, bridgeInfo: info);

      final proxies = (config['proxies'] as List).cast<Map<String, dynamic>>();
      // Bridge proxy was still added.
      expect(
        proxies.any((p) => p['name'] == kDropwebParazitXBridgeName),
        true,
      );

      // PROXY group must not be reshaped.
      final groups =
          (config['proxy-groups'] as List).cast<Map<String, dynamic>>();
      final proxyGroup = groups.firstWhere((g) => g['name'] == 'PROXY');
      expect(proxyGroup['proxies'], ['DIRECT']);
    });

    test('prepends static well-known DIRECT rules for self-loop protection',
        () {
      final config = <String, dynamic>{
        'proxies': <dynamic>[],
        'rules': <String>['MATCH,PROXY'],
      };
      const info = ParazitXBridgeInfo(host: '127.0.0.1', port: 18080);

      final result =
          ParazitXMihomoOrchestrator.applyToConfig(config, bridgeInfo: info);

      expect(result, isNotNull);
      expect(result!.directRulesAdded, greaterThanOrEqualTo(5));

      final rules = (config['rules'] as List).cast<String>();
      // VK signaling endpoints must be DIRECT.
      expect(rules, contains('DOMAIN-SUFFIX,vk.com,DIRECT'));
      // Yandex API Gateway zone must be DIRECT (for relay init).
      expect(rules, contains('DOMAIN-SUFFIX,apigw.yandexcloud.net,DIRECT'));
      // Existing catch-all preserved at the end.
      expect(rules.last, 'MATCH,PROXY');
    });

    test('appends caller-supplied extraDirectRules', () {
      final config = <String, dynamic>{
        'proxies': <dynamic>[],
        'rules': <String>['MATCH,PROXY'],
      };
      const info = ParazitXBridgeInfo(host: '127.0.0.1', port: 18080);

      ParazitXMihomoOrchestrator.applyToConfig(
        config,
        bridgeInfo: info,
        extraDirectRules: const <String>[
          'IP-CIDR,64.188.66.103/32,DIRECT,no-resolve',
        ],
      );

      final rules = (config['rules'] as List).cast<String>();
      expect(rules, contains('IP-CIDR,64.188.66.103/32,DIRECT,no-resolve'));
      expect(rules.last, 'MATCH,PROXY');
    });

    test('does NOT inject DIRECT rules when bridge is null', () {
      final config = <String, dynamic>{
        'proxies': <dynamic>[],
        'rules': <String>['MATCH,PROXY'],
      };
      ParazitXMihomoOrchestrator.applyToConfig(config, bridgeInfo: null);
      final rules = (config['rules'] as List).cast<String>();
      // Untouched.
      expect(rules, ['MATCH,PROXY']);
    });

    test('honors rulesKey for production "rule" (singular) shape', () {
      final config = <String, dynamic>{
        'proxies': <dynamic>[],
        // Note: 'rule' (singular), as state.dart::patchRawConfig leaves
        // the config in this shape before our orchestrator runs.
        'rule': <String>['MATCH,PROXY'],
      };
      const info = ParazitXBridgeInfo(host: '127.0.0.1', port: 18080);

      ParazitXMihomoOrchestrator.applyToConfig(
        config,
        bridgeInfo: info,
        rulesKey: 'rule',
        extraDirectRules: const <String>['DOMAIN,test.example,DIRECT'],
      );

      // 'rules' (plural) was never created.
      expect(config.containsKey('rules'), false);
      final rule = (config['rule'] as List).cast<String>();
      expect(rule, contains('DOMAIN-SUFFIX,vk.com,DIRECT'));
      expect(rule, contains('DOMAIN,test.example,DIRECT'));
      expect(rule.last, 'MATCH,PROXY');
    });

    test('deduplicates DIRECT rules across static and extra layers', () {
      final config = <String, dynamic>{
        'proxies': <dynamic>[],
        'rules': <String>['MATCH,PROXY'],
      };
      const info = ParazitXBridgeInfo(host: '127.0.0.1', port: 18080);

      final result = ParazitXMihomoOrchestrator.applyToConfig(
        config,
        bridgeInfo: info,
        // 'DOMAIN-SUFFIX,vk.com,DIRECT' is also in the static set.
        extraDirectRules: const <String>['DOMAIN-SUFFIX,vk.com,DIRECT'],
      );

      final rules = (config['rules'] as List).cast<String>();
      expect(
        rules.where((r) => r == 'DOMAIN-SUFFIX,vk.com,DIRECT').length,
        1,
      );
      expect(result, isNotNull);
    });

  });

  group('ParazitXBridgeInfo', () {
    test('toString includes host and port', () {
      const info = ParazitXBridgeInfo(host: '127.0.0.1', port: 1080);
      final s = info.toString();
      expect(s, contains('host=127.0.0.1'));
      expect(s, contains('port=1080'));
    });

    test('equality and hashCode include host and port', () {
      const a = ParazitXBridgeInfo(host: '127.0.0.1', port: 1080);
      const b = ParazitXBridgeInfo(host: '127.0.0.1', port: 1080);
      const c = ParazitXBridgeInfo(host: '127.0.0.1', port: 9999);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, false);
    });
  });
}
