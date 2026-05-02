import 'package:dropweb/services/mihomo_dialer_proxy_patcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> baseConfig() => <String, dynamic>{
        'proxies': <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'hy2-tokyo',
            'type': 'hysteria2',
            'server': 'hy2.example.com',
            'port': 443,
            'password': 'secret',
          },
          <String, dynamic>{
            'name': 'hy1-osaka',
            'type': 'hysteria',
            'server': 'hy1.example.com',
            'port': 443,
            'auth_str': 'secret',
          },
          <String, dynamic>{
            'name': 'vmess-frankfurt',
            'type': 'vmess',
            'server': 'vm.example.com',
            'port': 443,
          },
        ],
        'proxy-groups': <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'PROXY',
            'type': 'select',
            'proxies': <String>['hy2-tokyo', 'hy1-osaka', 'vmess-frankfurt'],
          },
        ],
        'rules': <String>['MATCH,PROXY'],
        'rule-providers': <String, dynamic>{
          'geoip-cn': <String, dynamic>{'type': 'http'},
        },
        'dns': <String, dynamic>{'enable': true},
        'tun': <String, dynamic>{'enable': true},
      };

  group('MihomoDialerProxyPatcher.patch', () {
    test('adds bridge proxy with correct fields', () {
      final config = baseConfig();
      final result = MihomoDialerProxyPatcher.patch(config, bridgePort: 1080);

      expect(result.bridgeAdded, true);
      expect(result.bridgeUpdated, false);

      final proxies = config['proxies'] as List;
      final bridge = proxies
          .cast<Map<String, dynamic>>()
          .firstWhere((p) => p['name'] == '__dropweb_parazitx_vk_bridge');
      expect(bridge['type'], 'socks5');
      expect(bridge['server'], '127.0.0.1');
      expect(bridge['port'], 1080);
    });

    test('adds dialer-proxy to hysteria and hysteria2 entries only', () {
      final config = baseConfig();
      final result = MihomoDialerProxyPatcher.patch(config, bridgePort: 1080);

      expect(result.patchedCount, 2);
      final proxies = (config['proxies'] as List).cast<Map<String, dynamic>>();
      final hy2 = proxies.firstWhere((p) => p['name'] == 'hy2-tokyo');
      final hy1 = proxies.firstWhere((p) => p['name'] == 'hy1-osaka');
      final vmess = proxies.firstWhere((p) => p['name'] == 'vmess-frankfurt');

      expect(hy2['dialer-proxy'], '__dropweb_parazitx_vk_bridge');
      expect(hy1['dialer-proxy'], '__dropweb_parazitx_vk_bridge');
      expect(vmess.containsKey('dialer-proxy'), false);
    });

    test('does not modify proxy-groups, rules, rule-providers, dns, tun', () {
      final config = baseConfig();
      final originalGroups = List<Map<String, dynamic>>.from(
        (config['proxy-groups'] as List).cast<Map<String, dynamic>>(),
      );
      final originalRules = List<String>.from(config['rules'] as List);
      final originalRuleProviders =
          Map<String, dynamic>.from(config['rule-providers'] as Map);
      final originalDns = Map<String, dynamic>.from(config['dns'] as Map);
      final originalTun = Map<String, dynamic>.from(config['tun'] as Map);

      MihomoDialerProxyPatcher.patch(config, bridgePort: 1080);

      expect(config['proxy-groups'], originalGroups);
      expect(config['rules'], originalRules);
      expect(config['rule-providers'], originalRuleProviders);
      expect(config['dns'], originalDns);
      expect(config['tun'], originalTun);
    });

    test('is idempotent: second patch updates port and does not duplicate', () {
      final config = baseConfig();
      MihomoDialerProxyPatcher.patch(config, bridgePort: 1080);
      final result2 = MihomoDialerProxyPatcher.patch(config, bridgePort: 1090);

      final proxies = (config['proxies'] as List).cast<Map<String, dynamic>>();
      final bridges = proxies
          .where((p) => p['name'] == '__dropweb_parazitx_vk_bridge')
          .toList();
      expect(bridges, hasLength(1));
      expect(bridges.single['port'], 1090);

      expect(result2.bridgeAdded, false);
      expect(result2.bridgeUpdated, true);
    });

    test('skips hysteria proxy with existing non-Dropweb dialer-proxy', () {
      final config = baseConfig();
      final proxies = (config['proxies'] as List).cast<Map<String, dynamic>>();
      proxies.firstWhere((p) => p['name'] == 'hy2-tokyo')['dialer-proxy'] =
          'user-bridge';

      final result = MihomoDialerProxyPatcher.patch(config, bridgePort: 1080);

      final hy2 = proxies.firstWhere((p) => p['name'] == 'hy2-tokyo');
      expect(hy2['dialer-proxy'], 'user-bridge');
      expect(result.skipped, hasLength(1));
      expect(result.skipped.single.name, 'hy2-tokyo');
      expect(result.patchedCount, 1); // hy1-osaka still patched
      expect(result.skippedCount, 1);
    });

    test('overwrites existing Dropweb-owned dialer-proxy on re-patch', () {
      final config = baseConfig();
      // First patch sets dialer-proxy = bridge name on hy2-tokyo / hy1-osaka.
      MihomoDialerProxyPatcher.patch(config, bridgePort: 1080);
      // Second patch must NOT treat our own marker as user override.
      final result2 = MihomoDialerProxyPatcher.patch(config, bridgePort: 1090);
      expect(result2.skippedCount, 0);
    });

    test('handles config without proxies field gracefully', () {
      final config = <String, dynamic>{};
      final result = MihomoDialerProxyPatcher.patch(config, bridgePort: 1080);

      expect(config.containsKey('proxies'), true);
      final proxies = (config['proxies'] as List).cast<Map<String, dynamic>>();
      expect(proxies, hasLength(1));
      expect(proxies.single['name'], '__dropweb_parazitx_vk_bridge');
      expect(result.bridgeAdded, true);
      expect(result.patchedCount, 0);
    });

    test('uses custom bridge server when provided', () {
      final config = <String, dynamic>{};
      MihomoDialerProxyPatcher.patch(
        config,
        bridgePort: 1080,
        bridgeServer: '127.0.0.2',
      );
      final proxies = (config['proxies'] as List).cast<Map<String, dynamic>>();
      expect(proxies.single['server'], '127.0.0.2');
    });

    test(
        'can append ParazitX bridge to select groups without changing selected value',
        () {
      final config = <String, dynamic>{
        'proxies': <dynamic>[],
        'proxy-groups': <dynamic>[
          <String, dynamic>{
            'name': 'GLOBAL',
            'type': 'select',
            'proxies': <String>['DIRECT'],
          },
          <String, dynamic>{
            'name': 'OTHER',
            'type': 'select',
            'proxies': <String>['DIRECT'],
          },
        ],
      };
      MihomoDialerProxyPatcher.patch(
        config,
        bridgePort: 18080,
        addToGroups: const ['GLOBAL'],
      );
      final groups =
          (config['proxy-groups'] as List).cast<Map<String, dynamic>>();
      final global = groups.firstWhere((g) => g['name'] == 'GLOBAL');
      final other = groups.firstWhere((g) => g['name'] == 'OTHER');
      expect(global['proxies'], ['DIRECT', kDropwebParazitXBridgeName]);
      // Other groups must remain untouched.
      expect(other['proxies'], ['DIRECT']);
      // Selected/default values must not be introduced.
      expect(global.containsKey('default'), false);
    });

    test('does not duplicate bridge name on repeated group append', () {
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
      MihomoDialerProxyPatcher.patch(
        config,
        bridgePort: 18080,
        addToGroups: const ['GLOBAL'],
      );
      MihomoDialerProxyPatcher.patch(
        config,
        bridgePort: 18080,
        addToGroups: const ['GLOBAL'],
      );
      final groups =
          (config['proxy-groups'] as List).cast<Map<String, dynamic>>();
      final global = groups.firstWhere((g) => g['name'] == 'GLOBAL');
      expect(global['proxies'], ['DIRECT', kDropwebParazitXBridgeName]);
    });

    test('skips groups that do not exist or have no proxies list', () {
      final config = <String, dynamic>{
        'proxies': <dynamic>[],
        'proxy-groups': <dynamic>[
          <String, dynamic>{
            'name': 'GLOBAL',
            'type': 'select',
            // Missing proxies list — must be skipped, not crash.
          },
        ],
      };
      MihomoDialerProxyPatcher.patch(
        config,
        bridgePort: 18080,
        addToGroups: const ['GLOBAL', 'NONEXISTENT'],
      );
      final groups =
          (config['proxy-groups'] as List).cast<Map<String, dynamic>>();
      final global = groups.firstWhere((g) => g['name'] == 'GLOBAL');
      // proxies key was missing; patcher must not invent one.
      expect(global.containsKey('proxies'), false);
      expect(groups.length, 1);
    });

    test('does not modify proxy-groups when addToGroups is empty/null', () {
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
      MihomoDialerProxyPatcher.patch(config, bridgePort: 18080);
      final groups =
          (config['proxy-groups'] as List).cast<Map<String, dynamic>>();
      expect(groups.first['proxies'], ['DIRECT']);
    });

    test('preserves existing selected/default fields on appended group', () {
      final config = <String, dynamic>{
        'proxies': <dynamic>[],
        'proxy-groups': <dynamic>[
          <String, dynamic>{
            'name': 'GLOBAL',
            'type': 'select',
            'proxies': <String>['DIRECT', 'PROXY-A'],
            'default': 'PROXY-A',
          },
        ],
      };
      MihomoDialerProxyPatcher.patch(
        config,
        bridgePort: 18080,
        addToGroups: const ['GLOBAL'],
      );
      final groups =
          (config['proxy-groups'] as List).cast<Map<String, dynamic>>();
      final global = groups.first;
      expect(global['default'], 'PROXY-A');
      expect(global['proxies'], [
        'DIRECT',
        'PROXY-A',
        kDropwebParazitXBridgeName,
      ]);
    });

    test('prepends directRules to the rules list', () {
      final config = <String, dynamic>{
        'proxies': <dynamic>[],
        'rules': <String>['MATCH,PROXY'],
      };
      final result = MihomoDialerProxyPatcher.patch(
        config,
        bridgePort: 18080,
        directRules: const <String>[
          'IP-CIDR,64.188.66.103/32,DIRECT,no-resolve',
          'DOMAIN-SUFFIX,vk.com,DIRECT',
        ],
      );
      final rules = (config['rules'] as List).cast<String>();
      expect(rules.first, 'IP-CIDR,64.188.66.103/32,DIRECT,no-resolve');
      expect(rules[1], 'DOMAIN-SUFFIX,vk.com,DIRECT');
      expect(rules.last, 'MATCH,PROXY');
      expect(result.directRulesAdded, 2);
    });

    test('directRules is idempotent (no duplicates on repeated patch)', () {
      final config = <String, dynamic>{
        'proxies': <dynamic>[],
        'rules': <String>['MATCH,PROXY'],
      };
      MihomoDialerProxyPatcher.patch(
        config,
        bridgePort: 18080,
        directRules: const <String>['DOMAIN-SUFFIX,vk.com,DIRECT'],
      );
      final result2 = MihomoDialerProxyPatcher.patch(
        config,
        bridgePort: 18080,
        directRules: const <String>['DOMAIN-SUFFIX,vk.com,DIRECT'],
      );
      final rules = (config['rules'] as List).cast<String>();
      expect(
        rules.where((r) => r == 'DOMAIN-SUFFIX,vk.com,DIRECT').length,
        1,
      );
      expect(rules.last, 'MATCH,PROXY');
      expect(result2.directRulesAdded, 0);
    });

    test('creates rules list when missing and directRules supplied', () {
      final config = <String, dynamic>{'proxies': <dynamic>[]};
      MihomoDialerProxyPatcher.patch(
        config,
        bridgePort: 18080,
        directRules: const <String>['DOMAIN-SUFFIX,vk.com,DIRECT'],
      );
      final rules = (config['rules'] as List).cast<String>();
      expect(rules, ['DOMAIN-SUFFIX,vk.com,DIRECT']);
    });

    test('does not touch rules when directRules is empty', () {
      final config = <String, dynamic>{
        'proxies': <dynamic>[],
        'rules': <String>['MATCH,PROXY'],
      };
      final result = MihomoDialerProxyPatcher.patch(
        config,
        bridgePort: 18080,
      );
      expect(config['rules'], <String>['MATCH,PROXY']);
      expect(result.directRulesAdded, 0);
    });

    test('skips empty/whitespace directRule entries', () {
      final config = <String, dynamic>{
        'proxies': <dynamic>[],
        'rules': <String>['MATCH,PROXY'],
      };
      final result = MihomoDialerProxyPatcher.patch(
        config,
        bridgePort: 18080,
        directRules: const <String>['', '   ', 'DOMAIN-SUFFIX,vk.com,DIRECT'],
      );
      final rules = (config['rules'] as List).cast<String>();
      expect(rules, ['DOMAIN-SUFFIX,vk.com,DIRECT', 'MATCH,PROXY']);
      expect(result.directRulesAdded, 1);
    });

    test(
        'preserves directRules order across rules even when they exist mid-list',
        () {
      final config = <String, dynamic>{
        'proxies': <dynamic>[],
        'rules': <String>[
          'DOMAIN-SUFFIX,old.example,DIRECT',
          'DOMAIN-SUFFIX,vk.com,DIRECT', // already present mid-list
          'MATCH,PROXY',
        ],
      };
      final result = MihomoDialerProxyPatcher.patch(
        config,
        bridgePort: 18080,
        directRules: const <String>[
          'IP-CIDR,64.188.66.103/32,DIRECT,no-resolve',
          'DOMAIN-SUFFIX,vk.com,DIRECT', // duplicate; must skip
        ],
      );
      final rules = (config['rules'] as List).cast<String>();
      // New rule prepended; existing duplicate left in place; order preserved.
      expect(rules, [
        'IP-CIDR,64.188.66.103/32,DIRECT,no-resolve',
        'DOMAIN-SUFFIX,old.example,DIRECT',
        'DOMAIN-SUFFIX,vk.com,DIRECT',
        'MATCH,PROXY',
      ]);
      expect(result.directRulesAdded, 1);
    });
  });
}
