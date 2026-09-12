import 'package:flutter/material.dart';

import '../widgets/mode_button.dart';

/// Asks before the automatic full catalog sync runs — this fires from
/// main.dart's bootstrap (a persisted "last synced" timestamp going stale),
/// not from a direct user action, so it needs its own explicit confirm
/// rather than just barging into a multi-minute blocking sync. Declining
/// leaves the last-synced timestamp untouched, so this asks again next
/// launch rather than silently postponing forever.
class CatalogSyncPromptScreen extends StatelessWidget {
  const CatalogSyncPromptScreen({super.key, required this.lastSyncedAt, required this.onRespond});

  final DateTime? lastSyncedAt;
  final void Function(bool confirmed) onRespond;

  String get _subtitle {
    final last = lastSyncedAt;
    if (last == null) return 'Your catalog has never been fully synced.';
    final days = DateTime.now().difference(last).inDays;
    if (days <= 0) return 'Your catalog was last fully synced earlier today.';
    return 'Your catalog was last fully synced $days day${days == 1 ? '' : 's'} ago.';
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_sync_outlined, color: Colors.white70, size: 48),
                  const SizedBox(height: 24),
                  const Text(
                    'Update content now?',
                    style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _subtitle,
                    style: const TextStyle(color: Colors.white70),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'This can take a few minutes on a large catalog. '
                    'Skipping opens the app with what\'s already cached.',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 28),
                  // Plain OutlinedButton/FilledButton here left which one
                  // has D-pad focus ambiguous — the FilledButton's own
                  // permanent solid fill reads as "this one's selected"
                  // regardless of actual focus, confirmed directly on
                  // hardware (focus was on "Skip for now", but "Update"
                  // visually looked selected). ModeButton is this app's
                  // established fix for exactly that: a solid fill *only*
                  // on real focus, distinct from any other visual state.
                  SizedBox(
                    width: 320,
                    child: Row(
                      children: [
                        Expanded(
                          child: ModeButton(
                            label: 'Skip for now',
                            selected: false,
                            onTap: () => onRespond(false),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: ModeButton(
                            label: 'Update',
                            selected: false,
                            onTap: () => onRespond(true),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
