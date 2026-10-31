import 'package:flutter/services.dart';

class PowerSnapshot {
  const PowerSnapshot({
    required this.currentUa,
    required this.voltageMv,
    required this.status,
    required this.plugged,
    required this.tempC,
    required this.isCharging,
    this.levelPercent = 0,
    this.chargeCounterUah = 0,
    this.capacityUah = 0,
  });

  final int currentUa;
  final int voltageMv;
  final int status;
  final int plugged;
  final double tempC;
  final bool isCharging;
  final double levelPercent;
  final double chargeCounterUah;
  final double capacityUah;

  bool get supported => currentUa != -2147483648 && voltageMv > 0;

  bool get charging => isCharging || status == 2 || status == 5 || plugged != 0;

  double get voltageV => voltageMv / 1000.0;

  double get currentA => currentUa / 1000000.0;

  /// Estimated full-pack energy in Wh, derived from the charge counter and
  /// current battery level. Returns null when the device does not expose it.
  double? get batteryCapacityWh {
    if (capacityUah <= 0 || voltageMv <= 0) return null;
    return (capacityUah / 1000000.0) * voltageV;
  }

  static Future<PowerSnapshot?> read(MethodChannel channel) async {
    try {
      final map = await channel.invokeMapMethod<String, dynamic>(
        'getPowerSnapshot',
      );
      if (map == null) return null;
      final current = (map['currentUa'] as num?)?.toInt() ?? -2147483648;
      final voltage = (map['voltageMv'] as num?)?.toInt() ?? -1;
      return PowerSnapshot(
        currentUa: current,
        voltageMv: voltage,
        status: (map['status'] as num?)?.toInt() ?? -1,
        plugged: (map['plugged'] as num?)?.toInt() ?? 0,
        tempC: (map['tempC'] as num?)?.toDouble() ?? 0,
        isCharging: map['isCharging'] as bool? ?? false,
        levelPercent: (map['levelPercent'] as num?)?.toDouble() ?? 0,
        chargeCounterUah: (map['chargeCounterUah'] as num?)?.toDouble() ?? 0,
        capacityUah: (map['capacityUah'] as num?)?.toDouble() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}

class PowerReading {
  const PowerReading(this.at, this.snapshot);

  final DateTime at;
  final PowerSnapshot snapshot;
}
