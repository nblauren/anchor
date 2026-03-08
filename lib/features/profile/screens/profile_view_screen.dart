import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/theme/app_theme.dart';
import '../../../features/settings/settings.dart';
import '../../../services/ble/ble.dart';
import '../../discovery/bloc/discovery_bloc.dart';
import '../bloc/profile_bloc.dart';
import '../bloc/profile_event.dart';
import '../bloc/profile_state.dart';
import '../widgets/photo_grid_widget.dart';
import '../widgets/photo_source_sheet.dart';
import '../widgets/profile_preview_widget.dart';

/// Screen for viewing and editing the user's own profile
class ProfileViewScreen extends StatefulWidget {
  const ProfileViewScreen({super.key});

  @override
  State<ProfileViewScreen> createState() => _ProfileViewScreenState();
}

class _ProfileViewScreenState extends State<ProfileViewScreen> {
  @override
  void initState() {
    super.initState();
    // Load profile when screen opens
    context.read<ProfileBloc>().add(const LoadProfile());
  }

  void _showPhotoSourceSheet() {
    PhotoSourceSheet.show(
      context,
      onCamera: () => context.read<ProfileBloc>().add(const PickPhotoFromCamera()),
      onGallery: () => context.read<ProfileBloc>().add(const PickPhotoFromGallery()),
    );
  }

  void _showEditDialog(ProfileState state) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.darkCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => _EditProfileSheet(
        name: state.name ?? '',
        age: state.age,
        bio: state.bio,
        onSave: (name, age, bio) {
          context.read<ProfileBloc>().add(UpdateProfile(
            name: name,
            age: age,
            bio: bio,
          ));
          Navigator.pop(context);
        },
      ),
    );
  }

  void _showPreviewDialog(ProfileState state) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: ProfilePreviewWidget(
          name: state.name,
          age: state.age,
          bio: state.bio,
          photos: state.sortedPhotos,
        ),
      ),
    );
  }

  void _openSettings(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MultiBlocProvider(
          providers: [
            BlocProvider.value(value: context.read<ProfileBloc>()),
            BlocProvider.value(value: context.read<DiscoveryBloc>()),
            BlocProvider.value(value: context.read<BleConnectionBloc>()),
          ],
          child: const SettingsScreen(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<ProfileBloc, ProfileState>(
      listener: (context, state) {
        // Show NSFW block alert when a photo is blocked from becoming primary
        if (state.nsfwBlockedPhotoId != null) {
          showDialog<void>(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('Sensitive Content Detected'),
              content: const Text(
                'This photo contains sensitive content and cannot be set as your '
                'primary (public) photo in Anchor. It can still be used as a '
                'secondary photo.',
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                    context.read<ProfileBloc>().add(const DismissNsfwWarning());
                  },
                  child: const Text('OK'),
                ),
              ],
            ),
          );
        }

        // Show errors
        if (state.errorMessage != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(state.errorMessage!)),
          );
          context.read<ProfileBloc>().add(const ClearError());
        }

        // Show success message on save
        if (state.status == ProfileStatus.saved) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Profile updated'),
              duration: Duration(seconds: 1),
            ),
          );
        }
      },
      builder: (context, state) {
        if (state.status == ProfileStatus.loading) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (state.status == ProfileStatus.noProfile) {
          return Scaffold(
            body: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.person_outline,
                    size: 64,
                    color: AppTheme.textSecondary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No profile yet',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: AppTheme.textSecondary,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Create your profile to get started',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppTheme.textHint,
                        ),
                  ),
                ],
              ),
            ),
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: const Text('My Profile'),
            actions: [
              IconButton(
                icon: const Icon(Icons.visibility),
                tooltip: 'Preview',
                onPressed: () => _showPreviewDialog(state),
              ),
              IconButton(
                icon: const Icon(Icons.settings),
                tooltip: 'Settings',
                onPressed: () => _openSettings(context),
              ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: () async {
              context.read<ProfileBloc>().add(const LoadProfile());
            },
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Profile info card
                  _buildProfileInfoCard(context, state),
                  const SizedBox(height: 24),

                  // Photos section
                  PhotoGridWidget(
                    photos: state.sortedPhotos,
                    onAddPhoto: _showPhotoSourceSheet,
                    onRemovePhoto: (photoId) =>
                        context.read<ProfileBloc>().add(RemovePhoto(photoId)),
                    onReorder: (photoIds) =>
                        context.read<ProfileBloc>().add(ReorderPhotos(photoIds)),
                    onSetPrimary: (photoId) =>
                        context.read<ProfileBloc>().add(SetPrimaryPhoto(photoId)),
                    isLoading: state.isProcessingPhoto,
                    maxPhotos: ProfileState.maxPhotos,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildProfileInfoCard(BuildContext context, ProfileState state) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.darkCard,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Profile Info',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              TextButton.icon(
                onPressed: () => _showEditDialog(state),
                icon: const Icon(Icons.edit, size: 18),
                label: const Text('Edit'),
              ),
            ],
          ),
          const Divider(),
          const SizedBox(height: 8),

          // Name
          _buildInfoRow(
            context,
            icon: Icons.person_outline,
            label: 'Name',
            value: state.name ?? 'Not set',
          ),
          const SizedBox(height: 12),

          // Age
          _buildInfoRow(
            context,
            icon: Icons.cake_outlined,
            label: 'Age',
            value: state.age?.toString() ?? 'Not set',
          ),
          const SizedBox(height: 12),

          // Bio
          _buildInfoRow(
            context,
            icon: Icons.edit_outlined,
            label: 'Bio',
            value: state.bio?.isNotEmpty == true ? state.bio! : 'Not set',
            maxLines: 3,
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    int maxLines = 1,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: AppTheme.textSecondary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppTheme.textHint,
                    ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: value == 'Not set'
                          ? AppTheme.textSecondary
                          : AppTheme.textPrimary,
                    ),
                maxLines: maxLines,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Bottom sheet for editing profile info
class _EditProfileSheet extends StatefulWidget {
  const _EditProfileSheet({
    required this.name,
    this.age,
    this.bio,
    required this.onSave,
  });

  final String name;
  final int? age;
  final String? bio;
  final Function(String name, int? age, String? bio) onSave;

  @override
  State<_EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends State<_EditProfileSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _ageController;
  late final TextEditingController _bioController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.name);
    _ageController = TextEditingController(
      text: widget.age?.toString() ?? '',
    );
    _bioController = TextEditingController(text: widget.bio ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _ageController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;

    widget.onSave(
      _nameController.text.trim(),
      _ageController.text.isNotEmpty ? int.tryParse(_ageController.text) : null,
      _bioController.text.trim().isNotEmpty ? _bioController.text.trim() : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle bar
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.textHint,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 24),

            Text(
              'Edit Profile',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 24),

            // Name field
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Name *',
                prefixIcon: Icon(Icons.person_outline),
              ),
              textCapitalization: TextCapitalization.words,
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Please enter your name';
                }
                if (value.trim().length < 2) {
                  return 'Name must be at least 2 characters';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),

            // Age field
            TextFormField(
              controller: _ageController,
              decoration: const InputDecoration(
                labelText: 'Age (optional)',
                prefixIcon: Icon(Icons.cake_outlined),
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(3),
              ],
              validator: (value) {
                if (value != null && value.isNotEmpty) {
                  final age = int.tryParse(value);
                  if (age == null || age < 18 || age > 120) {
                    return 'Please enter a valid age (18-120)';
                  }
                }
                return null;
              },
            ),
            const SizedBox(height: 16),

            // Bio field
            TextFormField(
              controller: _bioController,
              decoration: const InputDecoration(
                labelText: 'Bio (optional)',
                prefixIcon: Icon(Icons.edit_outlined),
                alignLabelWithHint: true,
              ),
              maxLines: 3,
              maxLength: 200,
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 24),

            // Save button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _save,
                child: const Text('Save Changes'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
