import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/viewer_profile_service.dart';
import '../utils/tv_theme.dart';
import '../widgets/settings_scaffold.dart';

/// Switch between viewer profiles — reached from the tabs column's own
/// profile row (TV) or the equivalent action on the phone layout. A plain
/// vertical list with no custom D-pad handling, autofocus on the current
/// profile — same "default traversal is the proven-reliable choice for a
/// simple list" principle `SettingsMenuScreen` documents, not a new
/// exception to it. Managing profiles (add/rename/delete/configure) lives
/// in Settings > Profiles instead, kept separate from quick switching here
/// the same way Netflix's own "Who's watching" picker is a different
/// screen from its profile-management one.
class ProfilePickerScreen extends StatelessWidget {
  const ProfilePickerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final viewers = context.watch<ViewerProfileService>();
    return withTvThemeIfNeeded(
      context,
      (context) => SettingsScaffold(
        title: 'Switch Profile',
        body: ListView(
          children: [
            for (final profile in viewers.profiles)
              ListTile(
                autofocus: profile.id == viewers.active.id,
                leading: CircleAvatar(
                  child: Text(
                      profile.name.isEmpty ? '?' : profile.name[0].toUpperCase()),
                ),
                title: Text(profile.name),
                subtitle: profile.isRestricted ? const Text('Restricted') : null,
                trailing: profile.id == viewers.active.id
                    ? const Icon(Icons.check_circle)
                    : null,
                onTap: () async {
                  final switched = await viewers.switchTo(context, profile.id);
                  if (!switched) return;
                  if (!context.mounted) return;
                  Navigator.of(context).pop();
                },
              ),
          ],
        ),
      ),
    );
  }
}
