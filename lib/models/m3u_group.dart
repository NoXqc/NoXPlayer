import 'channel.dart';

/// A `group-title` from the M3U playlist together with the channels that
/// belong to it. Computed on demand from the flat channel list — never
/// persisted directly, so it carries no JSON serialization.
class M3uGroup {
  M3uGroup({
    required this.title,
    required this.channels,
    this.isHidden = false,
  });

  final String title;
  final List<Channel> channels;
  final bool isHidden;
}
