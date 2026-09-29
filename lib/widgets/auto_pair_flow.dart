import 'package:flutter/material.dart';

/// Shared "Auto-Pair Channels" UX for both the EPG Channel Matching
/// screen and the cross-playlist Channel Linking screen — requested
/// directly in this exact shape: a "please wait" dialog while the pass
/// runs, then a choice to review just what changed or continue. Kept in
/// one place so the two screens' own auto-pair buttons can't drift apart
/// in behavior over time.
///
/// Runs [autoPair] behind the wait dialog, then asks the person whether
/// to review the result. `paired` is whatever [autoPair] returned
/// regardless of that choice (every caller's own picker screen needs it
/// either way, e.g. to invalidate a cached list); `review` is only true
/// when the person actually chose to look at what changed rather than
/// continue past it.
Future<({Set<String> paired, bool review})> runAutoPairFlow(
  BuildContext context, {
  required Future<Set<String>> Function() autoPair,
}) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Dialog(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 16),
            Flexible(child: Text('Channels are pairing, please wait…')),
          ],
        ),
      ),
    ),
  );

  final paired = await autoPair();

  if (!context.mounted) return (paired: paired, review: false);
  Navigator.of(context).pop(); // dismiss the wait dialog

  if (!context.mounted) return (paired: paired, review: false);
  final review = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Auto-Pair Channels'),
      content: Text(paired.isEmpty
          ? 'No new matches found — anything still unmatched needs a manual pick.'
          : 'Paired ${paired.length} channel${paired.length == 1 ? '' : 's'} '
              'automatically.'),
      actions: [
        if (paired.isNotEmpty)
          TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Review')),
        FilledButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Continue')),
      ],
    ),
  );
  return (paired: paired, review: review ?? false);
}

/// Shared "Unpair Channels" confirmation — undoes only what auto-pairing
/// itself set (never a manual pick), see the caller's own
/// `unpairAuto*`/`autoPaired*Count` doc comments for the actual rule.
/// Returns true only if the person confirmed and [unpair] actually ran.
Future<bool> confirmAndUnpair(
  BuildContext context, {
  required int autoPairedCount,
  required Future<int> Function() unpair,
}) async {
  if (autoPairedCount == 0) {
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Unpair Channels'),
        content:
            const Text('Nothing was auto-paired — there\'s nothing to undo.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK')),
        ],
      ),
    );
    return false;
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Unpair Channels'),
      content: Text(
          'Undo $autoPairedCount automatic pairing${autoPairedCount == 1 ? '' : 's'}? '
          'Anything you\'ve set by hand is kept.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Unpair')),
      ],
    ),
  );
  if (confirmed != true) return false;
  await unpair();
  return true;
}
