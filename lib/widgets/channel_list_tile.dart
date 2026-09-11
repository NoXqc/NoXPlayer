import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/channel.dart';
import '../services/playlist_manager.dart';
import 'epg_guide.dart';
import 'hold_to_activate.dart';

/// One row in the channel/program list: logo, name, current EPG program,
/// and a favorite (pin) toggle.
class ChannelListTile extends StatelessWidget {
  const ChannelListTile({
    super.key,
    required this.channel,
    required this.selected,
    required this.onTap,
    this.showEpg = true,
  });

  final Channel channel;
  final bool selected;
  final VoidCallback onTap;

  /// EPG only applies to live TV — movies/series episodes have no program
  /// guide entry, so showing "No program data" under every one of them is
  /// just noise.
  final bool showEpg;

  void _toggleFavorite(BuildContext context) {
    context.read<PlaylistManager>().toggleFavorite(channel);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(channel.isFavorite ? 'Added to Favorites' : 'Removed from Favorites'),
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return HoldToActivate(
      onTap: onTap,
      onHold: () => _toggleFavorite(context),
      child: ListTile(
        selected: selected,
        leading: SizedBox(
          width: 48,
          height: 48,
          child: (channel.logoUrl != null && channel.logoUrl!.isNotEmpty)
              ? Image.network(
                  channel.logoUrl!,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Icon(Icons.tv),
                )
              : const Icon(Icons.tv),
        ),
        title: Text(channel.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: EpgGuide(channelId: channel.id, compact: true),
        // Excluded from focus traversal (matches the equivalent star fix
        // already applied to the Live TV list, and the Slider in
        // PlayerControls) — without this, D-pad Up/Down here can land on
        // the star instead of moving to the next row.
        trailing: ExcludeFocus(
          child: IconButton(
            icon: Icon(
              channel.isFavorite ? Icons.star : Icons.star_border,
              color: channel.isFavorite ? Colors.amber : null,
            ),
            tooltip: channel.isFavorite ? 'Unpin' : 'Pin as favorite',
            onPressed: () => _toggleFavorite(context),
          ),
        ),
        onTap: onTap,
      ),
    );
  }
}
