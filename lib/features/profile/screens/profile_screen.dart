import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/theme/app_theme.dart';
import '../bloc/profile_bloc.dart';
import '../bloc/profile_event.dart';
import '../bloc/profile_state.dart';

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

        final profile = state.profile;
        if (profile == null) {
          return const Scaffold(
            body: Center(child: Text('No profile found')),
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: const Text('My Profile'),
            actions: [
              if (state.hasUnsavedChanges)
                TextButton(
                  onPressed: () {
                    context.read<ProfileBloc>().add(const SaveProfile());
                  },
                  child: const Text('Save'),
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
                // Profile photos carousel
                if (profile.photoUrls.isNotEmpty)
                  SizedBox(
                    height: 300,
                    child: PageView.builder(
                      itemCount: profile.photoUrls.length,
                      itemBuilder: (context, index) {
                        return Container(
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            image: DecorationImage(
                              image: FileImage(File(profile.photoUrls[index])),
                              fit: BoxFit.cover,
                            ),
                          ),
                        );
                      },
                    ),
                  )
                else
                  Container(
                    height: 300,
                    decoration: BoxDecoration(
                      color: AppTheme.darkCard,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Center(
                      child: Icon(Icons.person, size: 80, color: AppTheme.textSecondary),
                    ),
                  ),
                const SizedBox(height: 16),

                // Photo indicator dots
                if (profile.photoUrls.length > 1)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(
                      profile.photoUrls.length,
                      (index) => Container(
                        width: 8,
                        height: 8,
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: index == 0
                              ? AppTheme.primaryColor
                              : AppTheme.textSecondary,
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 24),

                // Name and age
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${profile.name}, ${profile.age}',
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit, color: AppTheme.primaryColor),
                      onPressed: () {
                        // TODO: Edit profile dialog
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Bio
                if (profile.bio != null && profile.bio!.isNotEmpty) ...[
                  Text(
                    'About me',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: AppTheme.textSecondary,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    profile.bio!,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 24),
                ],

                // Interests
                if (profile.interests.isNotEmpty) ...[
                  Text(
                    'Interests',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: AppTheme.textSecondary,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: profile.interests.map((interest) {
                      return Chip(
                        label: Text(interest),
                        backgroundColor: AppTheme.darkCard,
                      );
                    }).toList(),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
