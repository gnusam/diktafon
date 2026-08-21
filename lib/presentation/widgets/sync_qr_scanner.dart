/// Pairing by camera (fork addition).
///
/// The laptop address is a long string with a password and a token in it —
/// nothing anyone should retype, and there is no clipboard between the two
/// machines. The receiver prints it as a QR code (`pair-qr.sh`); this reads
/// it back.
///
/// Only offered where a camera scanner exists: on the desktop build the
/// plugin has no implementation, and the field is typed instead.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../l10n/l10n.dart';
import '../../services/sync/sync_target.dart';
import '../theme/tape_colors.dart';

bool get canScanQr =>
    !kIsWeb && (Platform.isAndroid || Platform.isIOS);

/// Opens the scanner and returns the scanned address, or null if the user
/// backed out. Only ever returns something [SyncTarget] understands — a
/// wifi or contact QR is ignored rather than pasted into the field.
Future<String?> scanSyncQr(BuildContext context) => Navigator.of(context)
    .push<String>(MaterialPageRoute(builder: (_) => const _QrScanScreen()));

class _QrScanScreen extends StatefulWidget {
  const _QrScanScreen();

  @override
  State<_QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<_QrScanScreen> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null || SyncTarget.parse(value) == null) continue;
      _done = true;
      Navigator.of(context).pop(value);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tape = context.tape;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.syncScanTitle)),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  l10n.syncScanFailed(error.errorCode.name),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: tape.ink),
                ),
              ),
            ),
          ),
          // The address is not a secret the camera should read by accident:
          // say what is being looked for.
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              color: tape.surface.withValues(alpha: 0.92),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Text(
                l10n.syncScanHint,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: tape.ink2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
