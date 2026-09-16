import 'package:flutter/services.dart';

/// Real device memory info from Android's ActivityManager — see
/// MainActivity.kt's doc comment for why this needs a small native call
/// (Flutter has no built-in way to ask "how much RAM does this device
/// have").
class DeviceMemoryInfo {
  const DeviceMemoryInfo(
      {required this.totalMemBytes, required this.isLowRamDevice});

  final int totalMemBytes;

  /// Android's own official "is this a memory-constrained device" flag
  /// (`ActivityManager.isLowRamDevice()`) — accounts for OEM-specific
  /// thresholds better than a flat GB cutoff would on its own.
  final bool isLowRamDevice;

  double get totalMemGB => totalMemBytes / (1024 * 1024 * 1024);
}

class DeviceMemoryService {
  static const _channel = MethodChannel('com.nox.nox_iptv/device_memory');

  /// Null on any failure (non-Android platform, channel not implemented,
  /// unexpected native exception) — callers must fall back to a safe,
  /// conservative default rather than guess or crash.
  static Future<DeviceMemoryInfo?> getMemoryInfo() async {
    try {
      final result =
          await _channel.invokeMapMethod<String, dynamic>('getMemoryInfo');
      if (result == null) return null;
      return DeviceMemoryInfo(
        totalMemBytes: result['totalMemBytes'] as int,
        isLowRamDevice: result['isLowRamDevice'] as bool,
      );
    } catch (_) {
      return null;
    }
  }
}
