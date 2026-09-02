/// Fork addition — the battery, as far as the job queue cares.
///
/// Whisper and the local LLM are the two things in this app that genuinely
/// drain a phone: minutes of pinned CPU, a warm case, and a battery curve
/// you can watch move. Below [lowBatteryPercent] on battery they wait.
///
/// What deliberately does *not* wait: recording (capturing a thought must
/// work at 3 %), the WAV→AAC transcode (hardware MediaCodec, cheap), and
/// above all the upload to the laptop — pushing a finished memo is a few
/// hundred kilobytes over HTTPS, and gating it would recreate the very
/// symptom this fork exists to remove, just with a different trigger.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

const _channel = EventChannel('diktafon/power');

/// Below this, on battery, the inference stages hold. A charger overrides it
/// at any level: plugged in, there is nothing to save.
const int lowBatteryPercent = 20;

/// What the gauge says. [level] is a percentage, or null when the platform
/// has no opinion — an unreadable gauge must never read as an empty one.
class PowerState {
  const PowerState({this.level, this.charging = false});

  /// What every platform but Android reports: desktop is on mains as far as
  /// this is concerned, and iOS suspends the work at backgrounding anyway.
  static const unknown = PowerState(charging: true);

  final int? level;
  final bool charging;

  /// The gate itself. Unknown level → allowed: a missing reading is not a
  /// reason to stop transcribing.
  bool get allowsInference =>
      charging || level == null || level! >= lowBatteryPercent;

  /// The level to show while the gate is shut, for the memo that is waiting.
  int? get holdingAt => allowsInference ? null : level;

  @override
  bool operator ==(Object other) =>
      other is PowerState && other.level == level && other.charging == charging;

  @override
  int get hashCode => Object.hash(level, charging);

  @override
  String toString() => 'PowerState(level: $level, charging: $charging)';
}

/// The live gauge. Off Android the stream is a single [PowerState.unknown]:
/// nothing to watch, and the gate stays open forever.
Stream<PowerState> powerStates() {
  if (!Platform.isAndroid) return Stream.value(PowerState.unknown);
  return _channel.receiveBroadcastStream().map((event) {
    final map = (event as Map).cast<Object?, Object?>();
    final level = map['level'] as int?;
    return PowerState(
      // The platform sends -1 for a gauge it could not read.
      level: level == null || level < 0 ? null : level,
      charging: map['charging'] as bool? ?? false,
    );
  }).handleError((_) {
    // A channel that fails is not a phone that must stop working.
  });
}
