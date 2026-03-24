import 'package:anchor/core/theme/app_theme.dart';
import 'package:anchor/core/utils/profile_validator.dart';
import 'package:anchor/features/discovery/bloc/discovery_bloc.dart';
import 'package:anchor/features/profile/bloc/profile_bloc.dart';
import 'package:anchor/features/profile/bloc/profile_event.dart';
import 'package:anchor/features/profile/bloc/profile_state.dart';
import 'package:anchor/features/profile/widgets/interests_chip_selector.dart';
import 'package:anchor/features/profile/widgets/photo_grid_widget.dart';
import 'package:anchor/features/profile/widgets/photo_source_sheet.dart';
import 'package:anchor/features/profile/widgets/position_chip_selector.dart';
import 'package:anchor/features/profile/widgets/profile_preview_widget.dart';
import 'package:anchor/features/settings/settings.dart';
import 'package:anchor/services/ble/ble.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

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
    showModalBottomSheet<void>(
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
        position: state.position,
        interestIds: state.interestIds,
        onSave: (name, age, bio, position, interests) {
          context.read<ProfileBloc>().add(UpdateProfile(
            name: name,
            age: age,
            bio: bio,
            position: position,
            clearPosition: position == null,
            interests: interests,
          ),);
          Navigator.pop(context);
        },
      ),
    );
  }

  void _showPreviewDialog(ProfileState state) {
    showDialog<void>(
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
      MaterialPageRoute<void>(
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
                key: const Key('profile_settings_btn'),
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
            value: state.bio?.isNotEmpty ?? false ? state.bio! : 'Not set',
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

/// Bottom sheet for editing profile info (all fields on one page)
class _EditProfileSheet extends StatefulWidget {
  const _EditProfileSheet({
    required this.name,
    required this.onSave, this.age,
    this.bio,
    this.position,
    this.interestIds = const [],
  });

  final String name;
  final int? age;
  final String? bio;
  final int? position;
  final List<int> interestIds;
  final void Function(
    String name,
    int? age,
    String? bio,
    int? position,
    List<int> interests,
  ) onSave;

  @override
  State<_EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends State<_EditProfileSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _ageController;
  late final TextEditingController _bioController;
  late int? _selectedPosition;
  late List<int> _selectedInterestIds;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.name);
    _ageController = TextEditingController(
      text: widget.age?.toString() ?? '',
    );
    _bioController = TextEditingController(text: widget.bio ?? '');
    _selectedPosition = widget.position;
    _selectedInterestIds = List<int>.from(widget.interestIds);
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

    final bio = _bioController.text.trim().isNotEmpty
        ? ProfileValidator.sanitizeBio(_bioController.text)
        : null;

    widget.onSave(
      _nameController.text.trim(),
      _ageController.text.isNotEmpty ? int.tryParse(_ageController.text) : null,
      bio,
      _selectedPosition,
      _selectedInterestIds,
    );
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Padding(
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 24,
          ),
          child: Form(
            key: _formKey,
            child: ListView(
              controller: scrollController,
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
                  maxLength: ProfileValidator.nicknameMaxLength,
                  validator: ProfileValidator.validateNickname,
                ),
                const SizedBox(height: 16),

                // Age field
                TextFormField(
                  controller: _ageController,
                  decoration: const InputDecoration(
                    labelText: 'Age *',
                    prefixIcon: Icon(Icons.cake_outlined),
                  ),
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(3),
                  ],
                  validator: ProfileValidator.validateAge,
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
                  maxLength: ProfileValidator.bioMaxLength,
                  textCapitalization: TextCapitalization.sentences,
                  validator: ProfileValidator.validateBio,
                ),
                const SizedBox(height: 20),

                // Position chips
                Text(
                  'Position',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: AppTheme.textSecondary,
                        letterSpacing: 0.5,
                      ),
                ),
                const SizedBox(height: 8),
                PositionChipSelector(
                  value: _selectedPosition,
                  onChanged: (id) => setState(() => _selectedPosition = id),
                ),
                const SizedBox(height: 20),

                // Interests chips
                Text(
                  'Interests',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: AppTheme.textSecondary,
                        letterSpacing: 0.5,
                      ),
                ),
                const SizedBox(height: 8),
                InterestsChipSelector(
                  selectedIds: _selectedInterestIds,
                  onChanged: (ids) =>
                      setState(() => _selectedInterestIds = ids),
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
      },
    );
  }
}
