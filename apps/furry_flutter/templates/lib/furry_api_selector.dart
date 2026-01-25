import 'dart:io';

import 'furry_api.dart';
import 'furry_api_android.dart';
import 'furry_api_ffi.dart';

FurryApi createFurryApi() {
  if (Platform.isAndroid) return FurryApiAndroid();
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) return FurryApiFfi();
  throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
}

