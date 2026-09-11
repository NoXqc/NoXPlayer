/// A single XMLTV `<programme>` entry: one show airing on one channel
/// between [start] and [stop].
class EpgProgram {
  EpgProgram({
    required this.channelId,
    required this.title,
    required this.start,
    required this.stop,
    this.description,
  });

  final String channelId;
  final String title;
  final String? description;
  final DateTime start;
  final DateTime stop;

  bool isNowPlaying(DateTime now) => !now.isBefore(start) && now.isBefore(stop);

  Map<String, dynamic> toJson() => {
        'channelId': channelId,
        'title': title,
        'description': description,
        'start': start.toIso8601String(),
        'stop': stop.toIso8601String(),
      };

  factory EpgProgram.fromJson(Map<String, dynamic> json) => EpgProgram(
        channelId: json['channelId'] as String,
        title: json['title'] as String,
        description: json['description'] as String?,
        start: DateTime.parse(json['start'] as String),
        stop: DateTime.parse(json['stop'] as String),
      );
}
