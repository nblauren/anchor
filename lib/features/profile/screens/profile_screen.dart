import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/profile_bloc.dart';
import '../bloc/profile_state.dart';
import '../widgets/profile_preview_widget.dart';

/// Screen showing the user's own profile with edit capabilities
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ProfileBloc, ProfileState>(
      builder: (context, state) {
        if (state.status == ProfileStatus.loading) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        // Check if profile exists
        if (state.profileId == null) {
          return const Scaffold(
            body: Center(child: Text('No profile found')),
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: const Text('My Profile'),
            actions: [
              IconButton(
                icon: const Icon(Icons.edit),
                onPressed: () {
                  // TODO: Navigate to edit screen or show edit dialog
                },
              ),
              IconButton(
                icon: const Icon(Icons.settings),
                onPressed: () {
                  // TODO: Navigate to settings
                },
              ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Profile preview using the existing widget
                ProfilePreviewWidget(
                  name: state.name,
                  age: state.age,
                  bio: state.bio,
                  photos: state.sortedPhotos,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
