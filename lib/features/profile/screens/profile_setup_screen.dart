import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/profile_validator.dart';
import '../bloc/profile_bloc.dart';
import '../bloc/profile_event.dart';
import '../bloc/profile_state.dart';
import '../widgets/interests_chip_selector.dart';
import '../widgets/photo_grid_widget.dart';
import '../widgets/photo_source_sheet.dart';
import '../widgets/position_chip_selector.dart';
import '../widgets/profile_preview_widget.dart';

/// Initial profile setup screen for new users (or editing existing profile).
///
/// Create flow: 7-step PageView (5 info steps + Photos + Preview).
/// Edit flow: same as before (single info page + photos + preview).
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
  final _nameFormKey = GlobalKey<FormState>();
  final _ageFormKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _ageController = TextEditingController();
  final _bioController = TextEditingController();
  final _pageController = PageController();

  int _currentPage = 0;
  bool _profileCreated = false;
  bool _initialized = false;

  int? _selectedPosition;
  List<int> _selectedInterestIds = [];
  bool _isQuickSetup = false;

  /// Total pages: 5 info steps + Photos + Preview = 7 for create,
  /// or 3 (single info + photos + preview) for edit.
  int get _totalPages => widget.isEditing ? 3 : 7;

  /// Index of the photos page.
  int get _photosPageIndex => widget.isEditing ? 1 : 5;

  /// The last info step index (where we save the profile).
  int get _lastInfoStepIndex => widget.isEditing ? 0 : 4;

  @override
  void initState() {
    super.initState();
    _profileCreated = widget.isEditing;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized && widget.isEditing) {
      final state = context.read<ProfileBloc>().state;
      _nameController.text = state.name ?? '';
      _ageController.text = state.age?.toString() ?? '';
      _bioController.text = state.bio ?? '';
      _selectedPosition = state.position;
      _selectedInterestIds = List<int>.from(state.interestIds);
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

  void _goToPage(int page) {
    // Dismiss keyboard when leaving text-input steps (name/age/bio).
    if (!widget.isEditing && _currentPage <= 2 && page > 2) {
      FocusScope.of(context).unfocus();
    }
    _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  void _nextPage() {
    // For edit mode, page 0 is the combined info page — validate and save.
    if (widget.isEditing && _currentPage == 0) {
      if (!_nameFormKey.currentState!.validate()) return;
      _saveProfile();
      return;
    }

    // For create mode, handle each step.
    if (!widget.isEditing) {
      if (_currentPage == 0) {
        // Step 1: Name — validate
        if (!_nameFormKey.currentState!.validate()) return;
      } else if (_currentPage == 1) {
        // Step 2: Age — validate if filled
        if (!_ageFormKey.currentState!.validate()) return;
      }

      // If this is the last info step, save profile.
      if (_currentPage == _lastInfoStepIndex) {
        _saveProfile();
        return;
      }
    }

    // Otherwise just advance.
    _goToPage(_currentPage + 1);
  }

  void _skipStep() {
    if (_currentPage == _lastInfoStepIndex) {
      _saveProfile();
      return;
    }
    _goToPage(_currentPage + 1);
  }

  void _saveProfile() {
    final bloc = context.read<ProfileBloc>();
    final bio = _bioController.text.trim().isNotEmpty
        ? ProfileValidator.sanitizeBio(_bioController.text)
        : null;
    if (!_profileCreated) {
      bloc.add(CreateProfile(
        name: _nameController.text.trim(),
        age: _ageController.text.isNotEmpty
            ? int.tryParse(_ageController.text)
            : null,
        bio: bio,
        position: _selectedPosition,
        interests: _selectedInterestIds,
      ));
    } else {
      bloc.add(UpdateProfile(
        name: _nameController.text.trim(),
        age: _ageController.text.isNotEmpty
            ? int.tryParse(_ageController.text)
            : null,
        bio: bio,
        position: _selectedPosition,
        clearPosition: _selectedPosition == null,
        interests: _selectedInterestIds,
      ));
    }
  }

  void _previousPage() {
    _goToPage(_currentPage - 1);
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
      onCamera: () =>
          context.read<ProfileBloc>().add(const PickPhotoFromCamera()),
      onGallery: () =>
          context.read<ProfileBloc>().add(const PickPhotoFromGallery()),
    );
  }

  String get _appBarTitle {
    if (widget.isEditing) return 'Edit Profile';
    if (_currentPage <= _lastInfoStepIndex) return 'Create Profile';
    if (_currentPage == _photosPageIndex) return 'Add Photos';
    return 'Preview';
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<ProfileBloc, ProfileState>(
      listener: (context, state) {
        // Quick setup — profile + photo already created, go straight to home.
        if (state.status == ProfileStatus.saved && _isQuickSetup) {
          _isQuickSetup = false;
          widget.onComplete?.call();
          return;
        }

        // Profile created/saved — advance to photos page.
        if (state.status == ProfileStatus.saved &&
            !_profileCreated &&
            _currentPage <= _lastInfoStepIndex) {
          setState(() => _profileCreated = true);
          _goToPage(_photosPageIndex);
        } else if (state.status == ProfileStatus.saved &&
            _profileCreated &&
            _currentPage <= _lastInfoStepIndex) {
          // Edit mode save — advance to photos.
          _goToPage(_photosPageIndex);
        }

        // NSFW block alert
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
            title: Text(_appBarTitle),
            leading: _currentPage > 0
                ? IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: _previousPage,
                  )
                : null,
            actions: [
              if (kDebugMode && !widget.isEditing)
                TextButton(
                  onPressed: state.status == ProfileStatus.saving
                      ? null
                      : () {
                          setState(() => _isQuickSetup = true);
                          context
                              .read<ProfileBloc>()
                              .add(const QuickSetupProfile());
                        },
                  child: const Text('Quick Setup'),
                ),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: [
                // Step dots
                if (widget.isEditing == false) _buildStepDots(),

                // Pages
                Expanded(
                  child: PageView(
                    controller: _pageController,
                    physics: const NeverScrollableScrollPhysics(),
                    onPageChanged: (page) =>
                        setState(() => _currentPage = page),
                    children: widget.isEditing
                        ? [
                            _buildEditInfoPage(state),
                            _buildPhotosPage(state),
                            _buildPreviewPage(state),
                          ]
                        : [
                            _buildNameStep(state),
                            _buildAgeStep(state),
                            _buildBioStep(state),
                            _buildPositionStep(state),
                            _buildInterestsStep(state),
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

  Widget _buildStepDots() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(_totalPages, (i) {
          final isActive = i == _currentPage;
          final isCompleted = i < _currentPage;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.symmetric(horizontal: 4),
            width: isActive ? 24 : 8,
            height: 8,
            decoration: BoxDecoration(
              color: isActive
                  ? AppTheme.primaryLight
                  : isCompleted
                      ? AppTheme.primaryLight.withAlpha(128)
                      : Colors.white24,
              borderRadius: BorderRadius.circular(4),
            ),
          );
        }),
      ),
    );
  }

  // ── Create flow: Step pages ──────────────────────────────────────────────

  Widget _buildStepLayout({
    required String title,
    required String subtitle,
    required Widget child,
    required VoidCallback onContinue,
    bool showSkip = false,
    VoidCallback? onSkip,
    bool isSaving = false,
    String continueLabel = 'Continue',
  }) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: AppTheme.textSecondary,
                ),
          ),
          const SizedBox(height: 32),
          Expanded(child: child),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: isSaving ? null : onContinue,
              child: isSaving
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Text(continueLabel),
            ),
          ),
          if (showSkip) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: isSaving ? null : (onSkip ?? _skipStep),
                child: const Text('Skip'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildNameStep(ProfileState state) {
    return _buildStepLayout(
      title: "What's your name?",
      subtitle: 'This is how others will see you.',
      onContinue: _nextPage,
      isSaving: state.status == ProfileStatus.saving,
      child: Form(
        key: _nameFormKey,
        child: TextFormField(
          key: const Key('profile_name_field'),
          controller: _nameController,
          decoration: const InputDecoration(
            hintText: 'Enter your name',
            prefixIcon: Icon(Icons.person_outline),
          ),
          textCapitalization: TextCapitalization.words,
          maxLength: ProfileValidator.nicknameMaxLength,
          autofocus: true,
          validator: ProfileValidator.validateNickname,
        ),
      ),
    );
  }

  Widget _buildAgeStep(ProfileState state) {
    return _buildStepLayout(
      title: 'How old are you?',
      subtitle: 'Required — you must be 18 or older.',
      onContinue: _nextPage,
      isSaving: state.status == ProfileStatus.saving,
      child: Form(
        key: _ageFormKey,
        child: TextFormField(
          key: const Key('profile_age_field'),
          controller: _ageController,
          decoration: const InputDecoration(
            hintText: 'Enter your age',
            prefixIcon: Icon(Icons.cake_outlined),
          ),
          keyboardType: TextInputType.number,
          autofocus: true,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(3),
          ],
          validator: ProfileValidator.validateAge,
        ),
      ),
    );
  }

  Widget _buildBioStep(ProfileState state) {
    return _buildStepLayout(
      title: 'Tell us about yourself',
      subtitle: 'A short bio to help others get to know you.',
      onContinue: _nextPage,
      showSkip: true,
      isSaving: state.status == ProfileStatus.saving,
      child: TextFormField(
        key: const Key('profile_bio_field'),
        controller: _bioController,
        decoration: const InputDecoration(
          hintText: 'Write something about yourself...',
          prefixIcon: Icon(Icons.edit_outlined),
          alignLabelWithHint: true,
        ),
        maxLines: 5,
        maxLength: ProfileValidator.bioMaxLength,
        textCapitalization: TextCapitalization.sentences,
        autofocus: true,
        validator: ProfileValidator.validateBio,
      ),
    );
  }

  Widget _buildPositionStep(ProfileState state) {
    return _buildStepLayout(
      title: "What's your position?",
      subtitle: 'Optional — tap to select, tap again to deselect.',
      onContinue: _nextPage,
      showSkip: true,
      isSaving: state.status == ProfileStatus.saving,
      child: SingleChildScrollView(
        child: PositionChipSelector(
          value: _selectedPosition,
          onChanged: (id) => setState(() => _selectedPosition = id),
        ),
      ),
    );
  }

  Widget _buildInterestsStep(ProfileState state) {
    return _buildStepLayout(
      title: 'What are you into?',
      subtitle: 'Pick up to 10 interests.',
      onContinue: _nextPage,
      showSkip: true,
      continueLabel: 'Continue',
      isSaving: state.status == ProfileStatus.saving,
      child: SingleChildScrollView(
        child: InterestsChipSelector(
          selectedIds: _selectedInterestIds,
          onChanged: (ids) => setState(() => _selectedInterestIds = ids),
        ),
      ),
    );
  }

  // ── Edit flow: single combined info page (same as old behavior) ─────────

  Widget _buildEditInfoPage(ProfileState state) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Form(
        key: _nameFormKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Edit your profile',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'Update your details below',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: AppTheme.textSecondary,
                  ),
            ),
            const SizedBox(height: 32),
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Name *',
                hintText: 'What should we call you?',
                prefixIcon: Icon(Icons.person_outline),
              ),
              textCapitalization: TextCapitalization.words,
              maxLength: ProfileValidator.nicknameMaxLength,
              validator: ProfileValidator.validateNickname,
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: _ageController,
              decoration: const InputDecoration(
                labelText: 'Age *',
                hintText: 'How old are you?',
                prefixIcon: Icon(Icons.cake_outlined),
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(3),
              ],
              validator: ProfileValidator.validateAge,
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: _bioController,
              decoration: const InputDecoration(
                labelText: 'Bio (optional)',
                hintText: 'Tell others about yourself...',
                prefixIcon: Icon(Icons.edit_outlined),
                alignLabelWithHint: true,
              ),
              maxLines: 4,
              maxLength: ProfileValidator.bioMaxLength,
              textCapitalization: TextCapitalization.sentences,
              validator: ProfileValidator.validateBio,
            ),
            const SizedBox(height: 20),
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
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed:
                    state.status == ProfileStatus.saving ? null : _nextPage,
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

  // ── Shared pages: Photos & Preview ──────────────────────────────────────

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
          ProfilePreviewWidget(
            name: state.name,
            age: state.age,
            bio: state.bio,
            photos: state.sortedPhotos,
          ),
          const SizedBox(height: 32),
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
                  child: Text(
                      widget.isEditing ? 'Save Changes' : 'Start Discovering'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
