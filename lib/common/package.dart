import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

extension PackageInfoExtension on PackageInfo {
  String get ua => [
        "clash-verge/v$version",
        "PinguVPN/v$version",
        "Platform/${Platform.operatingSystem}",
      ].join(" ");
}
