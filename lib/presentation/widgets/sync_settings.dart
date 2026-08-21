/// Settings for the laptop sync (fork addition).
///
/// Three rows and one dialog. The address is a single paste — the receiver
/// prints exactly the string that goes in here — and the dialog can test it
/// before saving, because a typo found now beats a memo silently parked in
/// a queue for a week.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers.dart';
import '../../data/repositories/settings_repository.dart';
import '../../l10n/l10n.dart';
import '../../services/sync/laptop_sync.dart';
import '../../services/sync/sync_target.dart';
import '../theme/tape_colors.dart';
import 'ink_toggle.dart';
import 'settings_rows.dart';

class SyncSettingsGroup extends ConsumerWidget {
  const SyncSettingsGroup({super.key, required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final repo = ref.read(settingsRepositoryProvider);
    final target = SyncTarget.parse(settings.syncUrl);
    final pending = ref.watch(pendingUploadsProvider).value ?? 0;

    return SettingsGroup(title: l10n.groupSync, rows: [
      SettingsRow(
        title: l10n.syncTarget,
        value: target?.displayName ?? l10n.syncTargetUnset,
        onTap: () => _editTarget(context, ref, repo),
      ),
      SettingsRow(
        title: l10n.syncAuto,
        value: l10n.syncAutoDesc,
        trailing: InkToggle(
          // Nothing to send to: the switch would promise a delivery the app
          // cannot make.
          value: settings.syncAuto && target != null,
          onChanged: target == null ? null : repo.setSyncAuto,
        ),
      ),
      // Only once there is somewhere to send to: with no address, "waiting
      // to be sent" would be waiting for nothing.
      if (target != null)
        SettingsRow(
          title: l10n.syncPendingRow,
          value:
              pending == 0 ? l10n.syncPendingNone : l10n.syncPending(pending),
          trailing: pending == 0
              ? null
              : Text(l10n.syncSendNow,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: context.tape.ink,
                  )),
          onTap: pending == 0
              ? null
              : () async {
                  await ref.read(jobQueueProvider).enqueueUploads();
                  if (context.mounted) _toast(context, l10n.syncQueued);
                },
        ),
    ]);
  }

  Future<void> _editTarget(
      BuildContext context, WidgetRef ref, SettingsRepository repo) async {
    final url = await showDialog<String>(
      context: context,
      builder: (_) => _SyncTargetDialog(initial: settings.syncUrl ?? ''),
    );
    if (url == null) return; // cancelled
    await repo.setSyncUrl(url);
    // A target that just appeared should pick up everything recorded before
    // it existed; one that just went away leaves its jobs parked (they cost
    // nothing and come back with the next address).
    if (SyncTarget.parse(url) != null) {
      await ref.read(jobQueueProvider).enqueueUploads();
    }
  }

  static void _toast(BuildContext context, String message) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
}

class _SyncTargetDialog extends ConsumerStatefulWidget {
  const _SyncTargetDialog({required this.initial});

  final String initial;

  @override
  ConsumerState<_SyncTargetDialog> createState() => _SyncTargetDialogState();
}

class _SyncTargetDialogState extends ConsumerState<_SyncTargetDialog> {
  late final _controller = TextEditingController(text: widget.initial);
  bool _testing = false;
  String? _result;
  bool _ok = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    final target = SyncTarget.parse(_controller.text);
    final l10n = context.l10n;
    if (target == null) {
      setState(() {
        _ok = false;
        _result = l10n.syncTargetInvalid;
      });
      return;
    }
    setState(() {
      _testing = true;
      _result = null;
    });
    try {
      final host = await ref.read(laptopSyncProvider).ping(target);
      if (!mounted) return;
      setState(() {
        _ok = true;
        _result = l10n.syncTestOk(host);
      });
    } on SyncException catch (e) {
      if (!mounted) return;
      setState(() {
        _ok = false;
        _result = l10n.syncTestFailed(e.toString());
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tape = context.tape;
    return AlertDialog(
      title: Text(l10n.syncTargetTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.syncTargetHint,
              style: TextStyle(fontSize: 12.5, color: tape.ink2)),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            maxLines: 2,
            minLines: 1,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              hintText: 'https://…',
              isDense: true,
            ),
            onChanged: (_) => setState(() => _result = null),
          ),
          if (_result != null) ...[
            const SizedBox(height: 10),
            Text(
              _result!,
              style: TextStyle(
                fontSize: 12.5,
                color: _ok ? tape.ink : Theme.of(context).colorScheme.error,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _testing ? null : _test,
          child: Text(_testing ? l10n.syncTesting : l10n.syncTest),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text(l10n.save),
        ),
      ],
    );
  }
}
