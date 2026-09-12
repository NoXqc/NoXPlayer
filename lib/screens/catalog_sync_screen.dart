import 'package:flutter/material.dart';

import '../services/playlist_manager.dart';

/// Blocking "Updating..." screen shown while a full catalog sync runs —
/// the TiviMate/MyTVOnline3-style pass [PlaylistManager.runFullCatalogSync]
/// does a few times a week (not on every launch): re-fetch category lists
/// and live channels, then every non-hidden VOD/series category's items,
/// so an ordinary day's launch opens straight into an already-populated
/// catalog instead of paying that network cost live while browsing.
///
/// Reads [playlist]'s progress fields via [ListenableBuilder] rather than
/// through Provider — this renders from main.dart's bootstrap gate, before
/// the app's `MultiProvider` tree exists.
class CatalogSyncScreen extends StatelessWidget {
  const CatalogSyncScreen({super.key, required this.playlist});

  final PlaylistManager playlist;

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
              child: ListenableBuilder(
                listenable: playlist,
                builder: (context, _) {
                  final total = playlist.warmCatalogTotal;
                  final done = playlist.warmCatalogDone;
                  final hasProgress = total > 0;
                  final fraction = hasProgress ? (done / total).clamp(0.0, 1.0) : null;
                  final phase = playlist.loadingPhase ??
                      (hasProgress ? 'Loading movies & TV shows...' : 'Connecting to server...');
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_sync_outlined, color: Colors.white70, size: 48),
                      const SizedBox(height: 24),
                      const Text(
                        'Updating Content',
                        style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        phase,
                        style: const TextStyle(color: Colors.white70),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: 260,
                        child: LinearProgressIndicator(value: fraction),
                      ),
                      if (hasProgress) ...[
                        const SizedBox(height: 8),
                        Text(
                          '$done / $total categories',
                          style: const TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                      ],
                      const SizedBox(height: 32),
                      const Text(
                        'This happens every few days to keep your catalog current — '
                        'everyday launches open straight in.',
                        style: TextStyle(color: Colors.white38, fontSize: 12),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
