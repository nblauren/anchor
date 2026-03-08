import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/theme/app_theme.dart';
import '../bloc/profile_bloc.dart';
import '../bloc/profile_event.dart';
import '../bloc/profile_state.dart';
import '../widgets/interests_chip_selector.dart';
import '../widgets/photo_grid_widget.dart';
import '../widgets/photo_source_sheet.dart';
import '../widgets/position_dropdown.dart';
import '../widgets/profile_preview_widget.dart';

/// Initial profile setup screen for new users (or editing existing profile)
class ProfileSetupScreen extends StatefulWidget {
  const ProfileSetupScreen({
    super.key,
    this.onComplete,
    this.isEditing = false,
  });

  final VoidCallback? onComplete;
  final bool isEditing;

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _ageController = TextEditingController();
  final _bioController = TextEditingController();
  final _pageController = PageController();

  int _currentPage = 0;
  bool _profileCreated = false;
  bool _initialized = false;

  // Optional "More About You" fields
  int? _selectedPosition;
  List<int> _selectedInterestIds = [];
  bool _moreAboutYouExpanded = false;

  @override
  void initState() {
    super.initState();
    // If editing, start with profile created flag true
    _profileCreated = widget.isEditing;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Pre-fill form fields if editing
    if (!_initialized && widget.isEditing) {
      final state = context.read<ProfileBloc>().state;
      _nameController.text = state.name ?? '';
      _ageController.text = state.age?.toString() ?? '';
      _bioController.text = state.bio ?? '';
      _selectedPosition = state.position;
      _selectedInterestIds = List<int>.from(state.interestIds);
      if (_selectedPosition != null || _selectedInterestIds.isNotEmpty) {
        _moreAboutYouExpanded = true;
      }
      _initialized = true;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _ageController.dispose();
    _bioController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _nextPage() {
    if (_currentPage == 0) {
      // Validate profile info before moving to photos
      if (!_formKey.currentState!.validate()) return;

      final bloc = context.read<ProfileBloc>();
      if (!_profileCreated) {
        // Create profile first
        bloc.add(CreateProfile(
          name: _nameController.text.trim(),
          age: _ageController.text.isNotEmpty ? int.tryParse(_ageController.text) : null,
          bio: _bioController.text.trim().isNotEmpty ? _bioController.text.trim() : null,
          position: _selectedPosition,
          interests: _selectedInterestIds,
        ));
      } else {
        // Update existing profile
        bloc.add(UpdateProfile(
          name: _nameController.text.trim(),
          age: _ageController.text.isNotEmpty ? int.tryParse(_ageController.text) : null,
          bio: _bioController.text.trim().isNotEmpty ? _bioController.text.trim() : null,
          position: _selectedPosition,
          clearPosition: _selectedPosition == null,
          interests: _selectedInterestIds,
        ));
      }
    } else {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _previousPage() {
    _pageController.previousPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  void _finishSetup() {
    final state = context.read<ProfileBloc>().state;
    if (state.photos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please add at least one photo')),
      );
      return;
    }
    widget.onComplete?.call();
  }

  void _showPhotoSourceSheet() {
    PhotoSourceSheet.show(
      context,
      onCamera: () => context.read<ProfileBloc>().add(const PickPhotoFromCamera()),
      onGallery: () => context.read<ProfileBloc>().add(const PickPhotoFromGallery()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<ProfileBloc, ProfileState>(
      listener: (context, state) {
        // Handle profile creation success - move to photos page
        if (state.status == ProfileStatus.saved && !_profileCreated && _currentPage == 0) {
          setState(() => _profileCreated = true);
          _pageController.nextPage(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
        }

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
      },
      builder: (context, state) {
        return Scaffold(
          appBar: AppBar(
            title: Text(widget.isEditing ? 'Edit Profile' : 'Create Profile'),
            leading: _currentPage > 0
                ? IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: _previousPage,
                  )
                : null,
          ),
          body: SafeArea(
            child: Column(
              children: [
                // Progress indicator
                LinearProgressIndicator(
                  value: (_currentPage + 1) / 3,
                  backgroundColor: AppTheme.darkCard,
                  valueColor: const AlwaysStoppedAnimation(AppTheme.primaryColor),
                ),

                // Pages
                Expanded(
                  child: PageView(
                    controller: _pageController,
                    physics: const NeverScrollableScrollPhysics(),
                    onPageChanged: (page) => setState(() => _currentPage = page),
                    children: [
                      _buildProfileInfoPage(state),
                      _buildPhotosPage(state),
                      _buildPreviewPage(state),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildProfileInfoPage(ProfileState state) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.isEditing ? 'Edit your profile' : 'Let\'s get started',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              widget.isEditing
                  ? 'Update your details below'
                  : 'Tell us a bit about yourself',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: AppTheme.textSecondary,
                  ),
            ),
            const SizedBox(height: 32),

            // Name field
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Name *',
                hintText: 'What should we call you?',
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
            const SizedBox(height: 20),

            // Age field
            TextFormField(
              controller: _ageController,
              decoration: const InputDecoration(
                labelText: 'Age (optional)',
                hintText: 'How old are you?',
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
            const SizedBox(height: 20),

            // Bio field
            TextFormField(
              controller: _bioController,
              decoration: const InputDecoration(
                labelText: 'Bio (optional)',
                hintText: 'Tell others about yourself...',
                prefixIcon: Icon(Icons.edit_outlined),
                alignLabelWithHint: true,
              ),
              maxLines: 4,
              maxLength: 200,
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 24),

            // ── Optional "More About You" collapsible section ──────────────
            _buildMoreAboutYouSection(),

            const SizedBox(height: 32),

            // Next button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: state.status == ProfileStatus.saving ? null : _nextPage,
                child: state.status == ProfileStatus.saving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Continue'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMoreAboutYouSection() {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.darkCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _moreAboutYouExpanded = !_moreAboutYouExpanded),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  const Icon(Icons.tune_rounded, size: 20, color: AppTheme.textSecondary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'More About You',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: AppTheme.textPrimary,
                          ),
                    ),
                  ),
                  Text(
                    'Optional',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppTheme.textHint,
                        ),
                  ),
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    turns: _moreAboutYouExpanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(Icons.keyboard_arrow_down,
                        color: AppTheme.textSecondary),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Divider(color: Colors.white12, height: 1),
                  const SizedBox(height: 16),
                  Text(
                    'Position',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: AppTheme.textSecondary,
                          letterSpacing: 0.5,
                        ),
                  ),
                  const SizedBox(height: 8),
                  PositionDropdown(
                    value: _selectedPosition,
                    onChanged: (id) => setState(() => _selectedPosition = id),
                  ),
                  const SizedBox(height: 20),
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
                    onChanged: (ids) => setState(() => _selectedInterestIds = ids),
                  ),
                ],
              ),
            ),
            crossFadeState: _moreAboutYouExpanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 250),
          ),
        ],
      ),
    );
  }

  Widget _buildPhotosPage(ProfileState state) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Add your photos',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Show off your best self! Your first photo will be shown in discovery.',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: AppTheme.textSecondary,
                ),
          ),
          const SizedBox(height: 24),

          // Photo grid
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

          const SizedBox(height: 32),

          // Navigation buttons
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _previousPage,
                  child: const Text('Back'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: state.photos.isNotEmpty ? _nextPage : null,
                  child: const Text('Preview Profile'),
                ),
              ),
            ],
          ),

          if (state.photos.isEmpty) ...[
            const SizedBox(height: 16),
            Text(
              'Add at least one photo to continue',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppTheme.warning,
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPreviewPage(ProfileState state) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Looking good!',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Here\'s how others will see you',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: AppTheme.textSecondary,
                ),
          ),
          const SizedBox(height: 24),

          // Profile preview
          ProfilePreviewWidget(
            name: state.name,
            age: state.age,
            bio: state.bio,
            photos: state.sortedPhotos,
          ),

          const SizedBox(height: 32),

          // Navigation buttons
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _previousPage,
                  child: const Text('Edit Photos'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: _finishSetup,
                  child: Text(widget.isEditing ? 'Save Changes' : 'Start Discovering'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
