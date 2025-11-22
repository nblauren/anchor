import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/theme/app_theme.dart';
import '../bloc/profile_bloc.dart';
import '../bloc/profile_event.dart';
import '../bloc/profile_state.dart';
import '../widgets/photo_picker_widget.dart';

/// Initial profile setup screen for new users
class ProfileSetupScreen extends StatefulWidget {
  const ProfileSetupScreen({super.key, this.onComplete});

  final VoidCallback? onComplete;

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _bioController = TextEditingController();
  int _age = 25;
  final List<File> _selectedPhotos = [];
  final List<String> _selectedInterests = [];

  final List<String> _availableInterests = [
    'Music',
    'Travel',
    'Food',
    'Movies',
    'Sports',
    'Art',
    'Reading',
    'Gaming',
    'Fitness',
    'Photography',
    'Nature',
    'Tech',
    'Fashion',
    'Cooking',
    'Dancing',
  ];

  @override
  void dispose() {
    _nameController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  void _onPhotoAdded(File photo) {
    setState(() {
      _selectedPhotos.add(photo);
    });
  }

  void _onPhotoRemoved(int index) {
    setState(() {
      _selectedPhotos.removeAt(index);
    });
  }

  void _toggleInterest(String interest) {
    setState(() {
      if (_selectedInterests.contains(interest)) {
        _selectedInterests.remove(interest);
      } else {
        _selectedInterests.add(interest);
      }
    });
  }

  void _submitProfile() {
    if (_formKey.currentState?.validate() != true) return;
    if (_selectedPhotos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please add at least one photo')),
      );
      return;
    }

    context.read<ProfileBloc>().add(CreateProfile(
          name: _nameController.text.trim(),
          age: _age,
          bio: _bioController.text.trim().isEmpty
              ? null
              : _bioController.text.trim(),
          photoFiles: _selectedPhotos,
          interests: _selectedInterests,
        ));
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<ProfileBloc, ProfileState>(
      listener: (context, state) {
        if (state.status == ProfileStatus.saved) {
          widget.onComplete?.call();
        } else if (state.status == ProfileStatus.error) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(state.errorMessage ?? 'An error occurred')),
          );
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Create Profile'),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Photos section
                  Text(
                    'Photos',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  PhotoPickerWidget(
                    photos: _selectedPhotos,
                    onPhotoAdded: _onPhotoAdded,
                    onPhotoRemoved: _onPhotoRemoved,
                  ),
                  const SizedBox(height: 24),

                  // Name field
                  TextFormField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      hintText: 'Enter your name',
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Please enter your name';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),

                  // Age slider
                  Text(
                    'Age: $_age',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Slider(
                    value: _age.toDouble(),
                    min: 18,
                    max: 100,
                    divisions: 82,
                    label: '$_age',
                    activeColor: AppTheme.primaryColor,
                    onChanged: (value) {
                      setState(() {
                        _age = value.round();
                      });
                    },
                  ),
                  const SizedBox(height: 16),

                  // Bio field
                  TextFormField(
                    controller: _bioController,
                    decoration: const InputDecoration(
                      labelText: 'Bio (optional)',
                      hintText: 'Tell us about yourself...',
                    ),
                    maxLines: 3,
                    maxLength: 500,
                  ),
                  const SizedBox(height: 24),

                  // Interests section
                  Text(
                    'Interests',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _availableInterests.map((interest) {
                      final isSelected = _selectedInterests.contains(interest);
                      return FilterChip(
                        label: Text(interest),
                        selected: isSelected,
                        onSelected: (_) => _toggleInterest(interest),
                        selectedColor: AppTheme.primaryColor.withOpacity(0.3),
                        checkmarkColor: AppTheme.primaryColor,
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 32),

                  // Submit button
                  BlocBuilder<ProfileBloc, ProfileState>(
                    builder: (context, state) {
                      final isLoading = state.status == ProfileStatus.saving;
                      return SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: isLoading ? null : _submitProfile,
                          child: isLoading
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text('Create Profile'),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
