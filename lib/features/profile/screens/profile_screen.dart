import 'package:anchor/features/profile/bloc/profile_bloc.dart';
import 'package:anchor/features/profile/bloc/profile_event.dart';
import 'package:anchor/features/profile/bloc/profile_state.dart';
import 'package:anchor/features/profile/screens/profile_setup_screen.dart';
import 'package:anchor/features/profile/widgets/profile_preview_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Screen showing the user's own profile with edit capabilities
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  void _openEditProfile(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BlocProvider.value(
          value: context.read<ProfileBloc>(),
          child: ProfileSetupScreen(
            isEditing: true,
            onComplete: () {
              Navigator.of(context).pop();
              // Reload profile & rebroadcast after edit
              context.read<ProfileBloc>().add(const LoadProfile());
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ProfileBloc, ProfileState>(
      builder: (context, state) {
        if (state.status == ProfileStatus.loading) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

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
                tooltip: 'Edit profile',
                onPressed: () => _openEditProfile(context),
              ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
