/// "Where does this cassette go on the laptop?" (fork addition).
///
/// Only ever asked once per cassette, and only when the laptop has no
/// answer of its own: a cassette named after a project directory is placed
/// without a word. The choices come *from* the laptop — the phone hands one
/// of them back by name, never a path it made up.
library;

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../services/sync/laptop_sync.dart';
import '../theme/tape_colors.dart';

Future<String?> askSyncDestination(
  BuildContext context, {
  required String label,
  required SyncDestination destination,
}) {
  final l10n = context.l10n;
  final tape = context.tape;
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: Text(l10n.syncDestinationTitle),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: Text(
            l10n.syncDestinationHint(label),
            style: TextStyle(fontSize: 12.5, color: tape.ink2),
          ),
        ),
        // The whole list scrolls inside the dialog: a laptop with forty
        // project directories must not push the buttons off screen.
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final choice in destination.choices)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(dialogContext, choice),
                    child: Text(choice,
                        style: const TextStyle(fontFamily: 'monospace')),
                  ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(dialogContext, destination.inbox),
          child: Text(l10n.syncDestinationInbox,
              style: TextStyle(color: tape.ink2)),
        ),
      ],
    ),
  );
}
