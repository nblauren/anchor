import 'package:equatable/equatable.dart';

/// User profile model for local storage and mesh network sharing
class UserProfile extends Equatable {
  const UserProfile({
    required this.id,
    required this.name,
    required this.age,
    this.bio,
    this.photoUrls = const [],
    this.interests = const [],
    required this.createdAt,
    required this.updatedAt,
    this.isOwnProfile = false,
    this.lastSeenAt,
    this.bleIdentifier,
  });

  final String id;
  final String name;
  final int age;
  final String? bio;
  final List<String> photoUrls;
  final List<String> interests;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isOwnProfile;
  final DateTime? lastSeenAt;
  final String? bleIdentifier;

  /// Creates a copy with updated fields
  UserProfile copyWith({
    String? id,
    String? name,
    int? age,
    String? bio,
    List<String>? photoUrls,
    List<String>? interests,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isOwnProfile,
    DateTime? lastSeenAt,
    String? bleIdentifier,
  }) {
    return UserProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      age: age ?? this.age,
      bio: bio ?? this.bio,
      photoUrls: photoUrls ?? this.photoUrls,
      interests: interests ?? this.interests,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isOwnProfile: isOwnProfile ?? this.isOwnProfile,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      bleIdentifier: bleIdentifier ?? this.bleIdentifier,
    );
  }

  /// Converts to JSON for storage/transmission
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'age': age,
      'bio': bio,
      'photoUrls': photoUrls,
      'interests': interests,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'isOwnProfile': isOwnProfile,
      'lastSeenAt': lastSeenAt?.toIso8601String(),
      'bleIdentifier': bleIdentifier,
    };
  }

  /// Creates from JSON
  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      age: json['age'] as int,
      bio: json['bio'] as String?,
      photoUrls: List<String>.from(json['photoUrls'] ?? []),
      interests: List<String>.from(json['interests'] ?? []),
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      isOwnProfile: json['isOwnProfile'] as bool? ?? false,
      lastSeenAt: json['lastSeenAt'] != null
          ? DateTime.parse(json['lastSeenAt'] as String)
          : null,
      bleIdentifier: json['bleIdentifier'] as String?,
    );
  }

  @override
  List<Object?> get props => [
        id,
        name,
        age,
        bio,
        photoUrls,
        interests,
        createdAt,
        updatedAt,
        isOwnProfile,
        lastSeenAt,
        bleIdentifier,
      ];
}
