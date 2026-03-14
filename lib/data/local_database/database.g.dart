// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $UserProfilesTable extends UserProfiles
    with TableInfo<$UserProfilesTable, UserProfileEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $UserProfilesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _ageMeta = const VerificationMeta('age');
  @override
  late final GeneratedColumn<int> age = GeneratedColumn<int>(
      'age', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _bioMeta = const VerificationMeta('bio');
  @override
  late final GeneratedColumn<String> bio = GeneratedColumn<String>(
      'bio', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _positionMeta =
      const VerificationMeta('position');
  @override
  late final GeneratedColumn<int> position = GeneratedColumn<int>(
      'position', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _interestsMeta =
      const VerificationMeta('interests');
  @override
  late final GeneratedColumn<String> interests = GeneratedColumn<String>(
      'interests', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [id, name, age, bio, position, interests, createdAt, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'user_profiles';
  @override
  VerificationContext validateIntegrity(Insertable<UserProfileEntry> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('age')) {
      context.handle(
          _ageMeta, age.isAcceptableOrUnknown(data['age']!, _ageMeta));
    }
    if (data.containsKey('bio')) {
      context.handle(
          _bioMeta, bio.isAcceptableOrUnknown(data['bio']!, _bioMeta));
    }
    if (data.containsKey('position')) {
      context.handle(_positionMeta,
          position.isAcceptableOrUnknown(data['position']!, _positionMeta));
    }
    if (data.containsKey('interests')) {
      context.handle(_interestsMeta,
          interests.isAcceptableOrUnknown(data['interests']!, _interestsMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  UserProfileEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return UserProfileEntry(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      age: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}age']),
      bio: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}bio']),
      position: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}position']),
      interests: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}interests']),
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $UserProfilesTable createAlias(String alias) {
    return $UserProfilesTable(attachedDatabase, alias);
  }
}

class UserProfileEntry extends DataClass
    implements Insertable<UserProfileEntry> {
  final String id;
  final String name;
  final int? age;
  final String? bio;

  /// Sexual position preference stored as a compact integer ID (see ProfileConstants.positionMap).
  /// null = not set.
  final int? position;

  /// Comma-separated interest IDs (e.g. "0,3,7"). null / empty = not set.
  /// See ProfileConstants.interestMap and encodeInterests / parseInterests.
  final String? interests;
  final DateTime createdAt;
  final DateTime updatedAt;
  const UserProfileEntry(
      {required this.id,
      required this.name,
      this.age,
      this.bio,
      this.position,
      this.interests,
      required this.createdAt,
      required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || age != null) {
      map['age'] = Variable<int>(age);
    }
    if (!nullToAbsent || bio != null) {
      map['bio'] = Variable<String>(bio);
    }
    if (!nullToAbsent || position != null) {
      map['position'] = Variable<int>(position);
    }
    if (!nullToAbsent || interests != null) {
      map['interests'] = Variable<String>(interests);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  UserProfilesCompanion toCompanion(bool nullToAbsent) {
    return UserProfilesCompanion(
      id: Value(id),
      name: Value(name),
      age: age == null && nullToAbsent ? const Value.absent() : Value(age),
      bio: bio == null && nullToAbsent ? const Value.absent() : Value(bio),
      position: position == null && nullToAbsent
          ? const Value.absent()
          : Value(position),
      interests: interests == null && nullToAbsent
          ? const Value.absent()
          : Value(interests),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory UserProfileEntry.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return UserProfileEntry(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      age: serializer.fromJson<int?>(json['age']),
      bio: serializer.fromJson<String?>(json['bio']),
      position: serializer.fromJson<int?>(json['position']),
      interests: serializer.fromJson<String?>(json['interests']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'age': serializer.toJson<int?>(age),
      'bio': serializer.toJson<String?>(bio),
      'position': serializer.toJson<int?>(position),
      'interests': serializer.toJson<String?>(interests),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  UserProfileEntry copyWith(
          {String? id,
          String? name,
          Value<int?> age = const Value.absent(),
          Value<String?> bio = const Value.absent(),
          Value<int?> position = const Value.absent(),
          Value<String?> interests = const Value.absent(),
          DateTime? createdAt,
          DateTime? updatedAt}) =>
      UserProfileEntry(
        id: id ?? this.id,
        name: name ?? this.name,
        age: age.present ? age.value : this.age,
        bio: bio.present ? bio.value : this.bio,
        position: position.present ? position.value : this.position,
        interests: interests.present ? interests.value : this.interests,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  UserProfileEntry copyWithCompanion(UserProfilesCompanion data) {
    return UserProfileEntry(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      age: data.age.present ? data.age.value : this.age,
      bio: data.bio.present ? data.bio.value : this.bio,
      position: data.position.present ? data.position.value : this.position,
      interests: data.interests.present ? data.interests.value : this.interests,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('UserProfileEntry(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('age: $age, ')
          ..write('bio: $bio, ')
          ..write('position: $position, ')
          ..write('interests: $interests, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id, name, age, bio, position, interests, createdAt, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is UserProfileEntry &&
          other.id == this.id &&
          other.name == this.name &&
          other.age == this.age &&
          other.bio == this.bio &&
          other.position == this.position &&
          other.interests == this.interests &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class UserProfilesCompanion extends UpdateCompanion<UserProfileEntry> {
  final Value<String> id;
  final Value<String> name;
  final Value<int?> age;
  final Value<String?> bio;
  final Value<int?> position;
  final Value<String?> interests;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const UserProfilesCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.age = const Value.absent(),
    this.bio = const Value.absent(),
    this.position = const Value.absent(),
    this.interests = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  UserProfilesCompanion.insert({
    required String id,
    required String name,
    this.age = const Value.absent(),
    this.bio = const Value.absent(),
    this.position = const Value.absent(),
    this.interests = const Value.absent(),
    required DateTime createdAt,
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        name = Value(name),
        createdAt = Value(createdAt),
        updatedAt = Value(updatedAt);
  static Insertable<UserProfileEntry> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<int>? age,
    Expression<String>? bio,
    Expression<int>? position,
    Expression<String>? interests,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (age != null) 'age': age,
      if (bio != null) 'bio': bio,
      if (position != null) 'position': position,
      if (interests != null) 'interests': interests,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  UserProfilesCompanion copyWith(
      {Value<String>? id,
      Value<String>? name,
      Value<int?>? age,
      Value<String?>? bio,
      Value<int?>? position,
      Value<String?>? interests,
      Value<DateTime>? createdAt,
      Value<DateTime>? updatedAt,
      Value<int>? rowid}) {
    return UserProfilesCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      age: age ?? this.age,
      bio: bio ?? this.bio,
      position: position ?? this.position,
      interests: interests ?? this.interests,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (age.present) {
      map['age'] = Variable<int>(age.value);
    }
    if (bio.present) {
      map['bio'] = Variable<String>(bio.value);
    }
    if (position.present) {
      map['position'] = Variable<int>(position.value);
    }
    if (interests.present) {
      map['interests'] = Variable<String>(interests.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('UserProfilesCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('age: $age, ')
          ..write('bio: $bio, ')
          ..write('position: $position, ')
          ..write('interests: $interests, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $UserPhotosTable extends UserPhotos
    with TableInfo<$UserPhotosTable, UserPhotoEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $UserPhotosTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<String> userId = GeneratedColumn<String>(
      'user_id', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES user_profiles (id)'));
  static const VerificationMeta _photoPathMeta =
      const VerificationMeta('photoPath');
  @override
  late final GeneratedColumn<String> photoPath = GeneratedColumn<String>(
      'photo_path', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _thumbnailPathMeta =
      const VerificationMeta('thumbnailPath');
  @override
  late final GeneratedColumn<String> thumbnailPath = GeneratedColumn<String>(
      'thumbnail_path', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _isPrimaryMeta =
      const VerificationMeta('isPrimary');
  @override
  late final GeneratedColumn<bool> isPrimary = GeneratedColumn<bool>(
      'is_primary', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("is_primary" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _orderIndexMeta =
      const VerificationMeta('orderIndex');
  @override
  late final GeneratedColumn<int> orderIndex = GeneratedColumn<int>(
      'order_index', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [id, userId, photoPath, thumbnailPath, isPrimary, orderIndex, createdAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'user_photos';
  @override
  VerificationContext validateIntegrity(Insertable<UserPhotoEntry> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('user_id')) {
      context.handle(_userIdMeta,
          userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta));
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    if (data.containsKey('photo_path')) {
      context.handle(_photoPathMeta,
          photoPath.isAcceptableOrUnknown(data['photo_path']!, _photoPathMeta));
    } else if (isInserting) {
      context.missing(_photoPathMeta);
    }
    if (data.containsKey('thumbnail_path')) {
      context.handle(
          _thumbnailPathMeta,
          thumbnailPath.isAcceptableOrUnknown(
              data['thumbnail_path']!, _thumbnailPathMeta));
    } else if (isInserting) {
      context.missing(_thumbnailPathMeta);
    }
    if (data.containsKey('is_primary')) {
      context.handle(_isPrimaryMeta,
          isPrimary.isAcceptableOrUnknown(data['is_primary']!, _isPrimaryMeta));
    }
    if (data.containsKey('order_index')) {
      context.handle(
          _orderIndexMeta,
          orderIndex.isAcceptableOrUnknown(
              data['order_index']!, _orderIndexMeta));
    } else if (isInserting) {
      context.missing(_orderIndexMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  UserPhotoEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return UserPhotoEntry(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      userId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}user_id'])!,
      photoPath: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}photo_path'])!,
      thumbnailPath: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}thumbnail_path'])!,
      isPrimary: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}is_primary'])!,
      orderIndex: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}order_index'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
    );
  }

  @override
  $UserPhotosTable createAlias(String alias) {
    return $UserPhotosTable(attachedDatabase, alias);
  }
}

class UserPhotoEntry extends DataClass implements Insertable<UserPhotoEntry> {
  final String id;
  final String userId;
  final String photoPath;
  final String thumbnailPath;
  final bool isPrimary;
  final int orderIndex;
  final DateTime createdAt;
  const UserPhotoEntry(
      {required this.id,
      required this.userId,
      required this.photoPath,
      required this.thumbnailPath,
      required this.isPrimary,
      required this.orderIndex,
      required this.createdAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['user_id'] = Variable<String>(userId);
    map['photo_path'] = Variable<String>(photoPath);
    map['thumbnail_path'] = Variable<String>(thumbnailPath);
    map['is_primary'] = Variable<bool>(isPrimary);
    map['order_index'] = Variable<int>(orderIndex);
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  UserPhotosCompanion toCompanion(bool nullToAbsent) {
    return UserPhotosCompanion(
      id: Value(id),
      userId: Value(userId),
      photoPath: Value(photoPath),
      thumbnailPath: Value(thumbnailPath),
      isPrimary: Value(isPrimary),
      orderIndex: Value(orderIndex),
      createdAt: Value(createdAt),
    );
  }

  factory UserPhotoEntry.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return UserPhotoEntry(
      id: serializer.fromJson<String>(json['id']),
      userId: serializer.fromJson<String>(json['userId']),
      photoPath: serializer.fromJson<String>(json['photoPath']),
      thumbnailPath: serializer.fromJson<String>(json['thumbnailPath']),
      isPrimary: serializer.fromJson<bool>(json['isPrimary']),
      orderIndex: serializer.fromJson<int>(json['orderIndex']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'userId': serializer.toJson<String>(userId),
      'photoPath': serializer.toJson<String>(photoPath),
      'thumbnailPath': serializer.toJson<String>(thumbnailPath),
      'isPrimary': serializer.toJson<bool>(isPrimary),
      'orderIndex': serializer.toJson<int>(orderIndex),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  UserPhotoEntry copyWith(
          {String? id,
          String? userId,
          String? photoPath,
          String? thumbnailPath,
          bool? isPrimary,
          int? orderIndex,
          DateTime? createdAt}) =>
      UserPhotoEntry(
        id: id ?? this.id,
        userId: userId ?? this.userId,
        photoPath: photoPath ?? this.photoPath,
        thumbnailPath: thumbnailPath ?? this.thumbnailPath,
        isPrimary: isPrimary ?? this.isPrimary,
        orderIndex: orderIndex ?? this.orderIndex,
        createdAt: createdAt ?? this.createdAt,
      );
  UserPhotoEntry copyWithCompanion(UserPhotosCompanion data) {
    return UserPhotoEntry(
      id: data.id.present ? data.id.value : this.id,
      userId: data.userId.present ? data.userId.value : this.userId,
      photoPath: data.photoPath.present ? data.photoPath.value : this.photoPath,
      thumbnailPath: data.thumbnailPath.present
          ? data.thumbnailPath.value
          : this.thumbnailPath,
      isPrimary: data.isPrimary.present ? data.isPrimary.value : this.isPrimary,
      orderIndex:
          data.orderIndex.present ? data.orderIndex.value : this.orderIndex,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('UserPhotoEntry(')
          ..write('id: $id, ')
          ..write('userId: $userId, ')
          ..write('photoPath: $photoPath, ')
          ..write('thumbnailPath: $thumbnailPath, ')
          ..write('isPrimary: $isPrimary, ')
          ..write('orderIndex: $orderIndex, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id, userId, photoPath, thumbnailPath, isPrimary, orderIndex, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is UserPhotoEntry &&
          other.id == this.id &&
          other.userId == this.userId &&
          other.photoPath == this.photoPath &&
          other.thumbnailPath == this.thumbnailPath &&
          other.isPrimary == this.isPrimary &&
          other.orderIndex == this.orderIndex &&
          other.createdAt == this.createdAt);
}

class UserPhotosCompanion extends UpdateCompanion<UserPhotoEntry> {
  final Value<String> id;
  final Value<String> userId;
  final Value<String> photoPath;
  final Value<String> thumbnailPath;
  final Value<bool> isPrimary;
  final Value<int> orderIndex;
  final Value<DateTime> createdAt;
  final Value<int> rowid;
  const UserPhotosCompanion({
    this.id = const Value.absent(),
    this.userId = const Value.absent(),
    this.photoPath = const Value.absent(),
    this.thumbnailPath = const Value.absent(),
    this.isPrimary = const Value.absent(),
    this.orderIndex = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  UserPhotosCompanion.insert({
    required String id,
    required String userId,
    required String photoPath,
    required String thumbnailPath,
    this.isPrimary = const Value.absent(),
    required int orderIndex,
    required DateTime createdAt,
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        userId = Value(userId),
        photoPath = Value(photoPath),
        thumbnailPath = Value(thumbnailPath),
        orderIndex = Value(orderIndex),
        createdAt = Value(createdAt);
  static Insertable<UserPhotoEntry> custom({
    Expression<String>? id,
    Expression<String>? userId,
    Expression<String>? photoPath,
    Expression<String>? thumbnailPath,
    Expression<bool>? isPrimary,
    Expression<int>? orderIndex,
    Expression<DateTime>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (userId != null) 'user_id': userId,
      if (photoPath != null) 'photo_path': photoPath,
      if (thumbnailPath != null) 'thumbnail_path': thumbnailPath,
      if (isPrimary != null) 'is_primary': isPrimary,
      if (orderIndex != null) 'order_index': orderIndex,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  UserPhotosCompanion copyWith(
      {Value<String>? id,
      Value<String>? userId,
      Value<String>? photoPath,
      Value<String>? thumbnailPath,
      Value<bool>? isPrimary,
      Value<int>? orderIndex,
      Value<DateTime>? createdAt,
      Value<int>? rowid}) {
    return UserPhotosCompanion(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      photoPath: photoPath ?? this.photoPath,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      isPrimary: isPrimary ?? this.isPrimary,
      orderIndex: orderIndex ?? this.orderIndex,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (userId.present) {
      map['user_id'] = Variable<String>(userId.value);
    }
    if (photoPath.present) {
      map['photo_path'] = Variable<String>(photoPath.value);
    }
    if (thumbnailPath.present) {
      map['thumbnail_path'] = Variable<String>(thumbnailPath.value);
    }
    if (isPrimary.present) {
      map['is_primary'] = Variable<bool>(isPrimary.value);
    }
    if (orderIndex.present) {
      map['order_index'] = Variable<int>(orderIndex.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('UserPhotosCompanion(')
          ..write('id: $id, ')
          ..write('userId: $userId, ')
          ..write('photoPath: $photoPath, ')
          ..write('thumbnailPath: $thumbnailPath, ')
          ..write('isPrimary: $isPrimary, ')
          ..write('orderIndex: $orderIndex, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $DiscoveredPeersTable extends DiscoveredPeers
    with TableInfo<$DiscoveredPeersTable, DiscoveredPeerEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DiscoveredPeersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _peerIdMeta = const VerificationMeta('peerId');
  @override
  late final GeneratedColumn<String> peerId = GeneratedColumn<String>(
      'peer_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<String> userId = GeneratedColumn<String>(
      'user_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _ageMeta = const VerificationMeta('age');
  @override
  late final GeneratedColumn<int> age = GeneratedColumn<int>(
      'age', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _bioMeta = const VerificationMeta('bio');
  @override
  late final GeneratedColumn<String> bio = GeneratedColumn<String>(
      'bio', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _thumbnailDataMeta =
      const VerificationMeta('thumbnailData');
  @override
  late final GeneratedColumn<Uint8List> thumbnailData =
      GeneratedColumn<Uint8List>('thumbnail_data', aliasedName, true,
          type: DriftSqlType.blob, requiredDuringInsert: false);
  static const VerificationMeta _lastSeenAtMeta =
      const VerificationMeta('lastSeenAt');
  @override
  late final GeneratedColumn<DateTime> lastSeenAt = GeneratedColumn<DateTime>(
      'last_seen_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _rssiMeta = const VerificationMeta('rssi');
  @override
  late final GeneratedColumn<int> rssi = GeneratedColumn<int>(
      'rssi', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _isBlockedMeta =
      const VerificationMeta('isBlocked');
  @override
  late final GeneratedColumn<bool> isBlocked = GeneratedColumn<bool>(
      'is_blocked', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("is_blocked" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _positionMeta =
      const VerificationMeta('position');
  @override
  late final GeneratedColumn<int> position = GeneratedColumn<int>(
      'position', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _interestsMeta =
      const VerificationMeta('interests');
  @override
  late final GeneratedColumn<String> interests = GeneratedColumn<String>(
      'interests', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        peerId,
        userId,
        name,
        age,
        bio,
        thumbnailData,
        lastSeenAt,
        rssi,
        isBlocked,
        position,
        interests
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'discovered_peers';
  @override
  VerificationContext validateIntegrity(
      Insertable<DiscoveredPeerEntry> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('peer_id')) {
      context.handle(_peerIdMeta,
          peerId.isAcceptableOrUnknown(data['peer_id']!, _peerIdMeta));
    } else if (isInserting) {
      context.missing(_peerIdMeta);
    }
    if (data.containsKey('user_id')) {
      context.handle(_userIdMeta,
          userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('age')) {
      context.handle(
          _ageMeta, age.isAcceptableOrUnknown(data['age']!, _ageMeta));
    }
    if (data.containsKey('bio')) {
      context.handle(
          _bioMeta, bio.isAcceptableOrUnknown(data['bio']!, _bioMeta));
    }
    if (data.containsKey('thumbnail_data')) {
      context.handle(
          _thumbnailDataMeta,
          thumbnailData.isAcceptableOrUnknown(
              data['thumbnail_data']!, _thumbnailDataMeta));
    }
    if (data.containsKey('last_seen_at')) {
      context.handle(
          _lastSeenAtMeta,
          lastSeenAt.isAcceptableOrUnknown(
              data['last_seen_at']!, _lastSeenAtMeta));
    } else if (isInserting) {
      context.missing(_lastSeenAtMeta);
    }
    if (data.containsKey('rssi')) {
      context.handle(
          _rssiMeta, rssi.isAcceptableOrUnknown(data['rssi']!, _rssiMeta));
    }
    if (data.containsKey('is_blocked')) {
      context.handle(_isBlockedMeta,
          isBlocked.isAcceptableOrUnknown(data['is_blocked']!, _isBlockedMeta));
    }
    if (data.containsKey('position')) {
      context.handle(_positionMeta,
          position.isAcceptableOrUnknown(data['position']!, _positionMeta));
    }
    if (data.containsKey('interests')) {
      context.handle(_interestsMeta,
          interests.isAcceptableOrUnknown(data['interests']!, _interestsMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {peerId};
  @override
  DiscoveredPeerEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DiscoveredPeerEntry(
      peerId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}peer_id'])!,
      userId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}user_id']),
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      age: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}age']),
      bio: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}bio']),
      thumbnailData: attachedDatabase.typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}thumbnail_data']),
      lastSeenAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}last_seen_at'])!,
      rssi: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}rssi']),
      isBlocked: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}is_blocked'])!,
      position: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}position']),
      interests: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}interests']),
    );
  }

  @override
  $DiscoveredPeersTable createAlias(String alias) {
    return $DiscoveredPeersTable(attachedDatabase, alias);
  }
}

class DiscoveredPeerEntry extends DataClass
    implements Insertable<DiscoveredPeerEntry> {
  final String peerId;

  /// Stable application-level user ID from the peer's BLE profile.
  /// Used to deduplicate when BLE MAC rotation assigns a new peerId.
  final String? userId;
  final String name;
  final int? age;
  final String? bio;
  final Uint8List? thumbnailData;
  final DateTime lastSeenAt;
  final int? rssi;
  final bool isBlocked;

  /// Position ID received from peer's BLE profile characteristic. null = not shared.
  final int? position;

  /// Comma-separated interest IDs received from peer. null / empty = not shared.
  final String? interests;
  const DiscoveredPeerEntry(
      {required this.peerId,
      this.userId,
      required this.name,
      this.age,
      this.bio,
      this.thumbnailData,
      required this.lastSeenAt,
      this.rssi,
      required this.isBlocked,
      this.position,
      this.interests});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['peer_id'] = Variable<String>(peerId);
    if (!nullToAbsent || userId != null) {
      map['user_id'] = Variable<String>(userId);
    }
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || age != null) {
      map['age'] = Variable<int>(age);
    }
    if (!nullToAbsent || bio != null) {
      map['bio'] = Variable<String>(bio);
    }
    if (!nullToAbsent || thumbnailData != null) {
      map['thumbnail_data'] = Variable<Uint8List>(thumbnailData);
    }
    map['last_seen_at'] = Variable<DateTime>(lastSeenAt);
    if (!nullToAbsent || rssi != null) {
      map['rssi'] = Variable<int>(rssi);
    }
    map['is_blocked'] = Variable<bool>(isBlocked);
    if (!nullToAbsent || position != null) {
      map['position'] = Variable<int>(position);
    }
    if (!nullToAbsent || interests != null) {
      map['interests'] = Variable<String>(interests);
    }
    return map;
  }

  DiscoveredPeersCompanion toCompanion(bool nullToAbsent) {
    return DiscoveredPeersCompanion(
      peerId: Value(peerId),
      userId:
          userId == null && nullToAbsent ? const Value.absent() : Value(userId),
      name: Value(name),
      age: age == null && nullToAbsent ? const Value.absent() : Value(age),
      bio: bio == null && nullToAbsent ? const Value.absent() : Value(bio),
      thumbnailData: thumbnailData == null && nullToAbsent
          ? const Value.absent()
          : Value(thumbnailData),
      lastSeenAt: Value(lastSeenAt),
      rssi: rssi == null && nullToAbsent ? const Value.absent() : Value(rssi),
      isBlocked: Value(isBlocked),
      position: position == null && nullToAbsent
          ? const Value.absent()
          : Value(position),
      interests: interests == null && nullToAbsent
          ? const Value.absent()
          : Value(interests),
    );
  }

  factory DiscoveredPeerEntry.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DiscoveredPeerEntry(
      peerId: serializer.fromJson<String>(json['peerId']),
      userId: serializer.fromJson<String?>(json['userId']),
      name: serializer.fromJson<String>(json['name']),
      age: serializer.fromJson<int?>(json['age']),
      bio: serializer.fromJson<String?>(json['bio']),
      thumbnailData: serializer.fromJson<Uint8List?>(json['thumbnailData']),
      lastSeenAt: serializer.fromJson<DateTime>(json['lastSeenAt']),
      rssi: serializer.fromJson<int?>(json['rssi']),
      isBlocked: serializer.fromJson<bool>(json['isBlocked']),
      position: serializer.fromJson<int?>(json['position']),
      interests: serializer.fromJson<String?>(json['interests']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'peerId': serializer.toJson<String>(peerId),
      'userId': serializer.toJson<String?>(userId),
      'name': serializer.toJson<String>(name),
      'age': serializer.toJson<int?>(age),
      'bio': serializer.toJson<String?>(bio),
      'thumbnailData': serializer.toJson<Uint8List?>(thumbnailData),
      'lastSeenAt': serializer.toJson<DateTime>(lastSeenAt),
      'rssi': serializer.toJson<int?>(rssi),
      'isBlocked': serializer.toJson<bool>(isBlocked),
      'position': serializer.toJson<int?>(position),
      'interests': serializer.toJson<String?>(interests),
    };
  }

  DiscoveredPeerEntry copyWith(
          {String? peerId,
          Value<String?> userId = const Value.absent(),
          String? name,
          Value<int?> age = const Value.absent(),
          Value<String?> bio = const Value.absent(),
          Value<Uint8List?> thumbnailData = const Value.absent(),
          DateTime? lastSeenAt,
          Value<int?> rssi = const Value.absent(),
          bool? isBlocked,
          Value<int?> position = const Value.absent(),
          Value<String?> interests = const Value.absent()}) =>
      DiscoveredPeerEntry(
        peerId: peerId ?? this.peerId,
        userId: userId.present ? userId.value : this.userId,
        name: name ?? this.name,
        age: age.present ? age.value : this.age,
        bio: bio.present ? bio.value : this.bio,
        thumbnailData:
            thumbnailData.present ? thumbnailData.value : this.thumbnailData,
        lastSeenAt: lastSeenAt ?? this.lastSeenAt,
        rssi: rssi.present ? rssi.value : this.rssi,
        isBlocked: isBlocked ?? this.isBlocked,
        position: position.present ? position.value : this.position,
        interests: interests.present ? interests.value : this.interests,
      );
  DiscoveredPeerEntry copyWithCompanion(DiscoveredPeersCompanion data) {
    return DiscoveredPeerEntry(
      peerId: data.peerId.present ? data.peerId.value : this.peerId,
      userId: data.userId.present ? data.userId.value : this.userId,
      name: data.name.present ? data.name.value : this.name,
      age: data.age.present ? data.age.value : this.age,
      bio: data.bio.present ? data.bio.value : this.bio,
      thumbnailData: data.thumbnailData.present
          ? data.thumbnailData.value
          : this.thumbnailData,
      lastSeenAt:
          data.lastSeenAt.present ? data.lastSeenAt.value : this.lastSeenAt,
      rssi: data.rssi.present ? data.rssi.value : this.rssi,
      isBlocked: data.isBlocked.present ? data.isBlocked.value : this.isBlocked,
      position: data.position.present ? data.position.value : this.position,
      interests: data.interests.present ? data.interests.value : this.interests,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DiscoveredPeerEntry(')
          ..write('peerId: $peerId, ')
          ..write('userId: $userId, ')
          ..write('name: $name, ')
          ..write('age: $age, ')
          ..write('bio: $bio, ')
          ..write('thumbnailData: $thumbnailData, ')
          ..write('lastSeenAt: $lastSeenAt, ')
          ..write('rssi: $rssi, ')
          ..write('isBlocked: $isBlocked, ')
          ..write('position: $position, ')
          ..write('interests: $interests')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      peerId,
      userId,
      name,
      age,
      bio,
      $driftBlobEquality.hash(thumbnailData),
      lastSeenAt,
      rssi,
      isBlocked,
      position,
      interests);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DiscoveredPeerEntry &&
          other.peerId == this.peerId &&
          other.userId == this.userId &&
          other.name == this.name &&
          other.age == this.age &&
          other.bio == this.bio &&
          $driftBlobEquality.equals(other.thumbnailData, this.thumbnailData) &&
          other.lastSeenAt == this.lastSeenAt &&
          other.rssi == this.rssi &&
          other.isBlocked == this.isBlocked &&
          other.position == this.position &&
          other.interests == this.interests);
}

class DiscoveredPeersCompanion extends UpdateCompanion<DiscoveredPeerEntry> {
  final Value<String> peerId;
  final Value<String?> userId;
  final Value<String> name;
  final Value<int?> age;
  final Value<String?> bio;
  final Value<Uint8List?> thumbnailData;
  final Value<DateTime> lastSeenAt;
  final Value<int?> rssi;
  final Value<bool> isBlocked;
  final Value<int?> position;
  final Value<String?> interests;
  final Value<int> rowid;
  const DiscoveredPeersCompanion({
    this.peerId = const Value.absent(),
    this.userId = const Value.absent(),
    this.name = const Value.absent(),
    this.age = const Value.absent(),
    this.bio = const Value.absent(),
    this.thumbnailData = const Value.absent(),
    this.lastSeenAt = const Value.absent(),
    this.rssi = const Value.absent(),
    this.isBlocked = const Value.absent(),
    this.position = const Value.absent(),
    this.interests = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  DiscoveredPeersCompanion.insert({
    required String peerId,
    this.userId = const Value.absent(),
    required String name,
    this.age = const Value.absent(),
    this.bio = const Value.absent(),
    this.thumbnailData = const Value.absent(),
    required DateTime lastSeenAt,
    this.rssi = const Value.absent(),
    this.isBlocked = const Value.absent(),
    this.position = const Value.absent(),
    this.interests = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : peerId = Value(peerId),
        name = Value(name),
        lastSeenAt = Value(lastSeenAt);
  static Insertable<DiscoveredPeerEntry> custom({
    Expression<String>? peerId,
    Expression<String>? userId,
    Expression<String>? name,
    Expression<int>? age,
    Expression<String>? bio,
    Expression<Uint8List>? thumbnailData,
    Expression<DateTime>? lastSeenAt,
    Expression<int>? rssi,
    Expression<bool>? isBlocked,
    Expression<int>? position,
    Expression<String>? interests,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (peerId != null) 'peer_id': peerId,
      if (userId != null) 'user_id': userId,
      if (name != null) 'name': name,
      if (age != null) 'age': age,
      if (bio != null) 'bio': bio,
      if (thumbnailData != null) 'thumbnail_data': thumbnailData,
      if (lastSeenAt != null) 'last_seen_at': lastSeenAt,
      if (rssi != null) 'rssi': rssi,
      if (isBlocked != null) 'is_blocked': isBlocked,
      if (position != null) 'position': position,
      if (interests != null) 'interests': interests,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DiscoveredPeersCompanion copyWith(
      {Value<String>? peerId,
      Value<String?>? userId,
      Value<String>? name,
      Value<int?>? age,
      Value<String?>? bio,
      Value<Uint8List?>? thumbnailData,
      Value<DateTime>? lastSeenAt,
      Value<int?>? rssi,
      Value<bool>? isBlocked,
      Value<int?>? position,
      Value<String?>? interests,
      Value<int>? rowid}) {
    return DiscoveredPeersCompanion(
      peerId: peerId ?? this.peerId,
      userId: userId ?? this.userId,
      name: name ?? this.name,
      age: age ?? this.age,
      bio: bio ?? this.bio,
      thumbnailData: thumbnailData ?? this.thumbnailData,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      rssi: rssi ?? this.rssi,
      isBlocked: isBlocked ?? this.isBlocked,
      position: position ?? this.position,
      interests: interests ?? this.interests,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (peerId.present) {
      map['peer_id'] = Variable<String>(peerId.value);
    }
    if (userId.present) {
      map['user_id'] = Variable<String>(userId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (age.present) {
      map['age'] = Variable<int>(age.value);
    }
    if (bio.present) {
      map['bio'] = Variable<String>(bio.value);
    }
    if (thumbnailData.present) {
      map['thumbnail_data'] = Variable<Uint8List>(thumbnailData.value);
    }
    if (lastSeenAt.present) {
      map['last_seen_at'] = Variable<DateTime>(lastSeenAt.value);
    }
    if (rssi.present) {
      map['rssi'] = Variable<int>(rssi.value);
    }
    if (isBlocked.present) {
      map['is_blocked'] = Variable<bool>(isBlocked.value);
    }
    if (position.present) {
      map['position'] = Variable<int>(position.value);
    }
    if (interests.present) {
      map['interests'] = Variable<String>(interests.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DiscoveredPeersCompanion(')
          ..write('peerId: $peerId, ')
          ..write('userId: $userId, ')
          ..write('name: $name, ')
          ..write('age: $age, ')
          ..write('bio: $bio, ')
          ..write('thumbnailData: $thumbnailData, ')
          ..write('lastSeenAt: $lastSeenAt, ')
          ..write('rssi: $rssi, ')
          ..write('isBlocked: $isBlocked, ')
          ..write('position: $position, ')
          ..write('interests: $interests, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ConversationsTable extends Conversations
    with TableInfo<$ConversationsTable, ConversationEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ConversationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _peerIdMeta = const VerificationMeta('peerId');
  @override
  late final GeneratedColumn<String> peerId = GeneratedColumn<String>(
      'peer_id', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'REFERENCES discovered_peers (peer_id)'));
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [id, peerId, createdAt, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'conversations';
  @override
  VerificationContext validateIntegrity(Insertable<ConversationEntry> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('peer_id')) {
      context.handle(_peerIdMeta,
          peerId.isAcceptableOrUnknown(data['peer_id']!, _peerIdMeta));
    } else if (isInserting) {
      context.missing(_peerIdMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ConversationEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ConversationEntry(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      peerId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}peer_id'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $ConversationsTable createAlias(String alias) {
    return $ConversationsTable(attachedDatabase, alias);
  }
}

class ConversationEntry extends DataClass
    implements Insertable<ConversationEntry> {
  final String id;
  final String peerId;
  final DateTime createdAt;
  final DateTime updatedAt;
  const ConversationEntry(
      {required this.id,
      required this.peerId,
      required this.createdAt,
      required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['peer_id'] = Variable<String>(peerId);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  ConversationsCompanion toCompanion(bool nullToAbsent) {
    return ConversationsCompanion(
      id: Value(id),
      peerId: Value(peerId),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory ConversationEntry.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ConversationEntry(
      id: serializer.fromJson<String>(json['id']),
      peerId: serializer.fromJson<String>(json['peerId']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'peerId': serializer.toJson<String>(peerId),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  ConversationEntry copyWith(
          {String? id,
          String? peerId,
          DateTime? createdAt,
          DateTime? updatedAt}) =>
      ConversationEntry(
        id: id ?? this.id,
        peerId: peerId ?? this.peerId,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  ConversationEntry copyWithCompanion(ConversationsCompanion data) {
    return ConversationEntry(
      id: data.id.present ? data.id.value : this.id,
      peerId: data.peerId.present ? data.peerId.value : this.peerId,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ConversationEntry(')
          ..write('id: $id, ')
          ..write('peerId: $peerId, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, peerId, createdAt, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ConversationEntry &&
          other.id == this.id &&
          other.peerId == this.peerId &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class ConversationsCompanion extends UpdateCompanion<ConversationEntry> {
  final Value<String> id;
  final Value<String> peerId;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const ConversationsCompanion({
    this.id = const Value.absent(),
    this.peerId = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ConversationsCompanion.insert({
    required String id,
    required String peerId,
    required DateTime createdAt,
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        peerId = Value(peerId),
        createdAt = Value(createdAt),
        updatedAt = Value(updatedAt);
  static Insertable<ConversationEntry> custom({
    Expression<String>? id,
    Expression<String>? peerId,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (peerId != null) 'peer_id': peerId,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ConversationsCompanion copyWith(
      {Value<String>? id,
      Value<String>? peerId,
      Value<DateTime>? createdAt,
      Value<DateTime>? updatedAt,
      Value<int>? rowid}) {
    return ConversationsCompanion(
      id: id ?? this.id,
      peerId: peerId ?? this.peerId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (peerId.present) {
      map['peer_id'] = Variable<String>(peerId.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ConversationsCompanion(')
          ..write('id: $id, ')
          ..write('peerId: $peerId, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MessagesTable extends Messages
    with TableInfo<$MessagesTable, MessageEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MessagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _conversationIdMeta =
      const VerificationMeta('conversationId');
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
      'conversation_id', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES conversations (id)'));
  static const VerificationMeta _senderIdMeta =
      const VerificationMeta('senderId');
  @override
  late final GeneratedColumn<String> senderId = GeneratedColumn<String>(
      'sender_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _contentTypeMeta =
      const VerificationMeta('contentType');
  @override
  late final GeneratedColumnWithTypeConverter<MessageContentType, String>
      contentType = GeneratedColumn<String>('content_type', aliasedName, false,
              type: DriftSqlType.string, requiredDuringInsert: true)
          .withConverter<MessageContentType>(
              $MessagesTable.$convertercontentType);
  static const VerificationMeta _textContentMeta =
      const VerificationMeta('textContent');
  @override
  late final GeneratedColumn<String> textContent = GeneratedColumn<String>(
      'text_content', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _photoPathMeta =
      const VerificationMeta('photoPath');
  @override
  late final GeneratedColumn<String> photoPath = GeneratedColumn<String>(
      'photo_path', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumnWithTypeConverter<MessageStatus, String> status =
      GeneratedColumn<String>('status', aliasedName, false,
              type: DriftSqlType.string, requiredDuringInsert: true)
          .withConverter<MessageStatus>($MessagesTable.$converterstatus);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        conversationId,
        senderId,
        contentType,
        textContent,
        photoPath,
        status,
        createdAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'messages';
  @override
  VerificationContext validateIntegrity(Insertable<MessageEntry> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('conversation_id')) {
      context.handle(
          _conversationIdMeta,
          conversationId.isAcceptableOrUnknown(
              data['conversation_id']!, _conversationIdMeta));
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('sender_id')) {
      context.handle(_senderIdMeta,
          senderId.isAcceptableOrUnknown(data['sender_id']!, _senderIdMeta));
    } else if (isInserting) {
      context.missing(_senderIdMeta);
    }
    context.handle(_contentTypeMeta, const VerificationResult.success());
    if (data.containsKey('text_content')) {
      context.handle(
          _textContentMeta,
          textContent.isAcceptableOrUnknown(
              data['text_content']!, _textContentMeta));
    }
    if (data.containsKey('photo_path')) {
      context.handle(_photoPathMeta,
          photoPath.isAcceptableOrUnknown(data['photo_path']!, _photoPathMeta));
    }
    context.handle(_statusMeta, const VerificationResult.success());
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  MessageEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MessageEntry(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      conversationId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}conversation_id'])!,
      senderId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sender_id'])!,
      contentType: $MessagesTable.$convertercontentType.fromSql(attachedDatabase
          .typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}content_type'])!),
      textContent: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}text_content']),
      photoPath: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}photo_path']),
      status: $MessagesTable.$converterstatus.fromSql(attachedDatabase
          .typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}status'])!),
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
    );
  }

  @override
  $MessagesTable createAlias(String alias) {
    return $MessagesTable(attachedDatabase, alias);
  }

  static JsonTypeConverter2<MessageContentType, String, String>
      $convertercontentType =
      const EnumNameConverter<MessageContentType>(MessageContentType.values);
  static JsonTypeConverter2<MessageStatus, String, String> $converterstatus =
      const EnumNameConverter<MessageStatus>(MessageStatus.values);
}

class MessageEntry extends DataClass implements Insertable<MessageEntry> {
  final String id;
  final String conversationId;
  final String senderId;
  final MessageContentType contentType;
  final String? textContent;
  final String? photoPath;
  final MessageStatus status;
  final DateTime createdAt;
  const MessageEntry(
      {required this.id,
      required this.conversationId,
      required this.senderId,
      required this.contentType,
      this.textContent,
      this.photoPath,
      required this.status,
      required this.createdAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['conversation_id'] = Variable<String>(conversationId);
    map['sender_id'] = Variable<String>(senderId);
    {
      map['content_type'] = Variable<String>(
          $MessagesTable.$convertercontentType.toSql(contentType));
    }
    if (!nullToAbsent || textContent != null) {
      map['text_content'] = Variable<String>(textContent);
    }
    if (!nullToAbsent || photoPath != null) {
      map['photo_path'] = Variable<String>(photoPath);
    }
    {
      map['status'] =
          Variable<String>($MessagesTable.$converterstatus.toSql(status));
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  MessagesCompanion toCompanion(bool nullToAbsent) {
    return MessagesCompanion(
      id: Value(id),
      conversationId: Value(conversationId),
      senderId: Value(senderId),
      contentType: Value(contentType),
      textContent: textContent == null && nullToAbsent
          ? const Value.absent()
          : Value(textContent),
      photoPath: photoPath == null && nullToAbsent
          ? const Value.absent()
          : Value(photoPath),
      status: Value(status),
      createdAt: Value(createdAt),
    );
  }

  factory MessageEntry.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MessageEntry(
      id: serializer.fromJson<String>(json['id']),
      conversationId: serializer.fromJson<String>(json['conversationId']),
      senderId: serializer.fromJson<String>(json['senderId']),
      contentType: $MessagesTable.$convertercontentType
          .fromJson(serializer.fromJson<String>(json['contentType'])),
      textContent: serializer.fromJson<String?>(json['textContent']),
      photoPath: serializer.fromJson<String?>(json['photoPath']),
      status: $MessagesTable.$converterstatus
          .fromJson(serializer.fromJson<String>(json['status'])),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'conversationId': serializer.toJson<String>(conversationId),
      'senderId': serializer.toJson<String>(senderId),
      'contentType': serializer.toJson<String>(
          $MessagesTable.$convertercontentType.toJson(contentType)),
      'textContent': serializer.toJson<String?>(textContent),
      'photoPath': serializer.toJson<String?>(photoPath),
      'status': serializer
          .toJson<String>($MessagesTable.$converterstatus.toJson(status)),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  MessageEntry copyWith(
          {String? id,
          String? conversationId,
          String? senderId,
          MessageContentType? contentType,
          Value<String?> textContent = const Value.absent(),
          Value<String?> photoPath = const Value.absent(),
          MessageStatus? status,
          DateTime? createdAt}) =>
      MessageEntry(
        id: id ?? this.id,
        conversationId: conversationId ?? this.conversationId,
        senderId: senderId ?? this.senderId,
        contentType: contentType ?? this.contentType,
        textContent: textContent.present ? textContent.value : this.textContent,
        photoPath: photoPath.present ? photoPath.value : this.photoPath,
        status: status ?? this.status,
        createdAt: createdAt ?? this.createdAt,
      );
  MessageEntry copyWithCompanion(MessagesCompanion data) {
    return MessageEntry(
      id: data.id.present ? data.id.value : this.id,
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      senderId: data.senderId.present ? data.senderId.value : this.senderId,
      contentType:
          data.contentType.present ? data.contentType.value : this.contentType,
      textContent:
          data.textContent.present ? data.textContent.value : this.textContent,
      photoPath: data.photoPath.present ? data.photoPath.value : this.photoPath,
      status: data.status.present ? data.status.value : this.status,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MessageEntry(')
          ..write('id: $id, ')
          ..write('conversationId: $conversationId, ')
          ..write('senderId: $senderId, ')
          ..write('contentType: $contentType, ')
          ..write('textContent: $textContent, ')
          ..write('photoPath: $photoPath, ')
          ..write('status: $status, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, conversationId, senderId, contentType,
      textContent, photoPath, status, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MessageEntry &&
          other.id == this.id &&
          other.conversationId == this.conversationId &&
          other.senderId == this.senderId &&
          other.contentType == this.contentType &&
          other.textContent == this.textContent &&
          other.photoPath == this.photoPath &&
          other.status == this.status &&
          other.createdAt == this.createdAt);
}

class MessagesCompanion extends UpdateCompanion<MessageEntry> {
  final Value<String> id;
  final Value<String> conversationId;
  final Value<String> senderId;
  final Value<MessageContentType> contentType;
  final Value<String?> textContent;
  final Value<String?> photoPath;
  final Value<MessageStatus> status;
  final Value<DateTime> createdAt;
  final Value<int> rowid;
  const MessagesCompanion({
    this.id = const Value.absent(),
    this.conversationId = const Value.absent(),
    this.senderId = const Value.absent(),
    this.contentType = const Value.absent(),
    this.textContent = const Value.absent(),
    this.photoPath = const Value.absent(),
    this.status = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MessagesCompanion.insert({
    required String id,
    required String conversationId,
    required String senderId,
    required MessageContentType contentType,
    this.textContent = const Value.absent(),
    this.photoPath = const Value.absent(),
    required MessageStatus status,
    required DateTime createdAt,
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        conversationId = Value(conversationId),
        senderId = Value(senderId),
        contentType = Value(contentType),
        status = Value(status),
        createdAt = Value(createdAt);
  static Insertable<MessageEntry> custom({
    Expression<String>? id,
    Expression<String>? conversationId,
    Expression<String>? senderId,
    Expression<String>? contentType,
    Expression<String>? textContent,
    Expression<String>? photoPath,
    Expression<String>? status,
    Expression<DateTime>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (conversationId != null) 'conversation_id': conversationId,
      if (senderId != null) 'sender_id': senderId,
      if (contentType != null) 'content_type': contentType,
      if (textContent != null) 'text_content': textContent,
      if (photoPath != null) 'photo_path': photoPath,
      if (status != null) 'status': status,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MessagesCompanion copyWith(
      {Value<String>? id,
      Value<String>? conversationId,
      Value<String>? senderId,
      Value<MessageContentType>? contentType,
      Value<String?>? textContent,
      Value<String?>? photoPath,
      Value<MessageStatus>? status,
      Value<DateTime>? createdAt,
      Value<int>? rowid}) {
    return MessagesCompanion(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      senderId: senderId ?? this.senderId,
      contentType: contentType ?? this.contentType,
      textContent: textContent ?? this.textContent,
      photoPath: photoPath ?? this.photoPath,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (senderId.present) {
      map['sender_id'] = Variable<String>(senderId.value);
    }
    if (contentType.present) {
      map['content_type'] = Variable<String>(
          $MessagesTable.$convertercontentType.toSql(contentType.value));
    }
    if (textContent.present) {
      map['text_content'] = Variable<String>(textContent.value);
    }
    if (photoPath.present) {
      map['photo_path'] = Variable<String>(photoPath.value);
    }
    if (status.present) {
      map['status'] =
          Variable<String>($MessagesTable.$converterstatus.toSql(status.value));
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MessagesCompanion(')
          ..write('id: $id, ')
          ..write('conversationId: $conversationId, ')
          ..write('senderId: $senderId, ')
          ..write('contentType: $contentType, ')
          ..write('textContent: $textContent, ')
          ..write('photoPath: $photoPath, ')
          ..write('status: $status, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AnchorDropsTable extends AnchorDrops
    with TableInfo<$AnchorDropsTable, AnchorDropEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AnchorDropsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _peerIdMeta = const VerificationMeta('peerId');
  @override
  late final GeneratedColumn<String> peerId = GeneratedColumn<String>(
      'peer_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _peerNameMeta =
      const VerificationMeta('peerName');
  @override
  late final GeneratedColumn<String> peerName = GeneratedColumn<String>(
      'peer_name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _directionMeta =
      const VerificationMeta('direction');
  @override
  late final GeneratedColumnWithTypeConverter<AnchorDropDirection, String>
      direction = GeneratedColumn<String>('direction', aliasedName, false,
              type: DriftSqlType.string, requiredDuringInsert: true)
          .withConverter<AnchorDropDirection>(
              $AnchorDropsTable.$converterdirection);
  static const VerificationMeta _droppedAtMeta =
      const VerificationMeta('droppedAt');
  @override
  late final GeneratedColumn<DateTime> droppedAt = GeneratedColumn<DateTime>(
      'dropped_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [id, peerId, peerName, direction, droppedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'anchor_drops';
  @override
  VerificationContext validateIntegrity(Insertable<AnchorDropEntry> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('peer_id')) {
      context.handle(_peerIdMeta,
          peerId.isAcceptableOrUnknown(data['peer_id']!, _peerIdMeta));
    } else if (isInserting) {
      context.missing(_peerIdMeta);
    }
    if (data.containsKey('peer_name')) {
      context.handle(_peerNameMeta,
          peerName.isAcceptableOrUnknown(data['peer_name']!, _peerNameMeta));
    } else if (isInserting) {
      context.missing(_peerNameMeta);
    }
    context.handle(_directionMeta, const VerificationResult.success());
    if (data.containsKey('dropped_at')) {
      context.handle(_droppedAtMeta,
          droppedAt.isAcceptableOrUnknown(data['dropped_at']!, _droppedAtMeta));
    } else if (isInserting) {
      context.missing(_droppedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AnchorDropEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AnchorDropEntry(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      peerId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}peer_id'])!,
      peerName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}peer_name'])!,
      direction: $AnchorDropsTable.$converterdirection.fromSql(attachedDatabase
          .typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}direction'])!),
      droppedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}dropped_at'])!,
    );
  }

  @override
  $AnchorDropsTable createAlias(String alias) {
    return $AnchorDropsTable(attachedDatabase, alias);
  }

  static JsonTypeConverter2<AnchorDropDirection, String, String>
      $converterdirection =
      const EnumNameConverter<AnchorDropDirection>(AnchorDropDirection.values);
}

class AnchorDropEntry extends DataClass implements Insertable<AnchorDropEntry> {
  final String id;
  final String peerId;
  final String peerName;
  final AnchorDropDirection direction;
  final DateTime droppedAt;
  const AnchorDropEntry(
      {required this.id,
      required this.peerId,
      required this.peerName,
      required this.direction,
      required this.droppedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['peer_id'] = Variable<String>(peerId);
    map['peer_name'] = Variable<String>(peerName);
    {
      map['direction'] = Variable<String>(
          $AnchorDropsTable.$converterdirection.toSql(direction));
    }
    map['dropped_at'] = Variable<DateTime>(droppedAt);
    return map;
  }

  AnchorDropsCompanion toCompanion(bool nullToAbsent) {
    return AnchorDropsCompanion(
      id: Value(id),
      peerId: Value(peerId),
      peerName: Value(peerName),
      direction: Value(direction),
      droppedAt: Value(droppedAt),
    );
  }

  factory AnchorDropEntry.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AnchorDropEntry(
      id: serializer.fromJson<String>(json['id']),
      peerId: serializer.fromJson<String>(json['peerId']),
      peerName: serializer.fromJson<String>(json['peerName']),
      direction: $AnchorDropsTable.$converterdirection
          .fromJson(serializer.fromJson<String>(json['direction'])),
      droppedAt: serializer.fromJson<DateTime>(json['droppedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'peerId': serializer.toJson<String>(peerId),
      'peerName': serializer.toJson<String>(peerName),
      'direction': serializer.toJson<String>(
          $AnchorDropsTable.$converterdirection.toJson(direction)),
      'droppedAt': serializer.toJson<DateTime>(droppedAt),
    };
  }

  AnchorDropEntry copyWith(
          {String? id,
          String? peerId,
          String? peerName,
          AnchorDropDirection? direction,
          DateTime? droppedAt}) =>
      AnchorDropEntry(
        id: id ?? this.id,
        peerId: peerId ?? this.peerId,
        peerName: peerName ?? this.peerName,
        direction: direction ?? this.direction,
        droppedAt: droppedAt ?? this.droppedAt,
      );
  AnchorDropEntry copyWithCompanion(AnchorDropsCompanion data) {
    return AnchorDropEntry(
      id: data.id.present ? data.id.value : this.id,
      peerId: data.peerId.present ? data.peerId.value : this.peerId,
      peerName: data.peerName.present ? data.peerName.value : this.peerName,
      direction: data.direction.present ? data.direction.value : this.direction,
      droppedAt: data.droppedAt.present ? data.droppedAt.value : this.droppedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AnchorDropEntry(')
          ..write('id: $id, ')
          ..write('peerId: $peerId, ')
          ..write('peerName: $peerName, ')
          ..write('direction: $direction, ')
          ..write('droppedAt: $droppedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, peerId, peerName, direction, droppedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AnchorDropEntry &&
          other.id == this.id &&
          other.peerId == this.peerId &&
          other.peerName == this.peerName &&
          other.direction == this.direction &&
          other.droppedAt == this.droppedAt);
}

class AnchorDropsCompanion extends UpdateCompanion<AnchorDropEntry> {
  final Value<String> id;
  final Value<String> peerId;
  final Value<String> peerName;
  final Value<AnchorDropDirection> direction;
  final Value<DateTime> droppedAt;
  final Value<int> rowid;
  const AnchorDropsCompanion({
    this.id = const Value.absent(),
    this.peerId = const Value.absent(),
    this.peerName = const Value.absent(),
    this.direction = const Value.absent(),
    this.droppedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AnchorDropsCompanion.insert({
    required String id,
    required String peerId,
    required String peerName,
    required AnchorDropDirection direction,
    required DateTime droppedAt,
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        peerId = Value(peerId),
        peerName = Value(peerName),
        direction = Value(direction),
        droppedAt = Value(droppedAt);
  static Insertable<AnchorDropEntry> custom({
    Expression<String>? id,
    Expression<String>? peerId,
    Expression<String>? peerName,
    Expression<String>? direction,
    Expression<DateTime>? droppedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (peerId != null) 'peer_id': peerId,
      if (peerName != null) 'peer_name': peerName,
      if (direction != null) 'direction': direction,
      if (droppedAt != null) 'dropped_at': droppedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AnchorDropsCompanion copyWith(
      {Value<String>? id,
      Value<String>? peerId,
      Value<String>? peerName,
      Value<AnchorDropDirection>? direction,
      Value<DateTime>? droppedAt,
      Value<int>? rowid}) {
    return AnchorDropsCompanion(
      id: id ?? this.id,
      peerId: peerId ?? this.peerId,
      peerName: peerName ?? this.peerName,
      direction: direction ?? this.direction,
      droppedAt: droppedAt ?? this.droppedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (peerId.present) {
      map['peer_id'] = Variable<String>(peerId.value);
    }
    if (peerName.present) {
      map['peer_name'] = Variable<String>(peerName.value);
    }
    if (direction.present) {
      map['direction'] = Variable<String>(
          $AnchorDropsTable.$converterdirection.toSql(direction.value));
    }
    if (droppedAt.present) {
      map['dropped_at'] = Variable<DateTime>(droppedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AnchorDropsCompanion(')
          ..write('id: $id, ')
          ..write('peerId: $peerId, ')
          ..write('peerName: $peerName, ')
          ..write('direction: $direction, ')
          ..write('droppedAt: $droppedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $BlockedUsersTable extends BlockedUsers
    with TableInfo<$BlockedUsersTable, BlockedUserEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BlockedUsersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _peerIdMeta = const VerificationMeta('peerId');
  @override
  late final GeneratedColumn<String> peerId = GeneratedColumn<String>(
      'peer_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _blockedAtMeta =
      const VerificationMeta('blockedAt');
  @override
  late final GeneratedColumn<DateTime> blockedAt = GeneratedColumn<DateTime>(
      'blocked_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [peerId, blockedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'blocked_users';
  @override
  VerificationContext validateIntegrity(Insertable<BlockedUserEntry> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('peer_id')) {
      context.handle(_peerIdMeta,
          peerId.isAcceptableOrUnknown(data['peer_id']!, _peerIdMeta));
    } else if (isInserting) {
      context.missing(_peerIdMeta);
    }
    if (data.containsKey('blocked_at')) {
      context.handle(_blockedAtMeta,
          blockedAt.isAcceptableOrUnknown(data['blocked_at']!, _blockedAtMeta));
    } else if (isInserting) {
      context.missing(_blockedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {peerId};
  @override
  BlockedUserEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return BlockedUserEntry(
      peerId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}peer_id'])!,
      blockedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}blocked_at'])!,
    );
  }

  @override
  $BlockedUsersTable createAlias(String alias) {
    return $BlockedUsersTable(attachedDatabase, alias);
  }
}

class BlockedUserEntry extends DataClass
    implements Insertable<BlockedUserEntry> {
  final String peerId;
  final DateTime blockedAt;
  const BlockedUserEntry({required this.peerId, required this.blockedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['peer_id'] = Variable<String>(peerId);
    map['blocked_at'] = Variable<DateTime>(blockedAt);
    return map;
  }

  BlockedUsersCompanion toCompanion(bool nullToAbsent) {
    return BlockedUsersCompanion(
      peerId: Value(peerId),
      blockedAt: Value(blockedAt),
    );
  }

  factory BlockedUserEntry.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return BlockedUserEntry(
      peerId: serializer.fromJson<String>(json['peerId']),
      blockedAt: serializer.fromJson<DateTime>(json['blockedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'peerId': serializer.toJson<String>(peerId),
      'blockedAt': serializer.toJson<DateTime>(blockedAt),
    };
  }

  BlockedUserEntry copyWith({String? peerId, DateTime? blockedAt}) =>
      BlockedUserEntry(
        peerId: peerId ?? this.peerId,
        blockedAt: blockedAt ?? this.blockedAt,
      );
  BlockedUserEntry copyWithCompanion(BlockedUsersCompanion data) {
    return BlockedUserEntry(
      peerId: data.peerId.present ? data.peerId.value : this.peerId,
      blockedAt: data.blockedAt.present ? data.blockedAt.value : this.blockedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('BlockedUserEntry(')
          ..write('peerId: $peerId, ')
          ..write('blockedAt: $blockedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(peerId, blockedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BlockedUserEntry &&
          other.peerId == this.peerId &&
          other.blockedAt == this.blockedAt);
}

class BlockedUsersCompanion extends UpdateCompanion<BlockedUserEntry> {
  final Value<String> peerId;
  final Value<DateTime> blockedAt;
  final Value<int> rowid;
  const BlockedUsersCompanion({
    this.peerId = const Value.absent(),
    this.blockedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  BlockedUsersCompanion.insert({
    required String peerId,
    required DateTime blockedAt,
    this.rowid = const Value.absent(),
  })  : peerId = Value(peerId),
        blockedAt = Value(blockedAt);
  static Insertable<BlockedUserEntry> custom({
    Expression<String>? peerId,
    Expression<DateTime>? blockedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (peerId != null) 'peer_id': peerId,
      if (blockedAt != null) 'blocked_at': blockedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  BlockedUsersCompanion copyWith(
      {Value<String>? peerId, Value<DateTime>? blockedAt, Value<int>? rowid}) {
    return BlockedUsersCompanion(
      peerId: peerId ?? this.peerId,
      blockedAt: blockedAt ?? this.blockedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (peerId.present) {
      map['peer_id'] = Variable<String>(peerId.value);
    }
    if (blockedAt.present) {
      map['blocked_at'] = Variable<DateTime>(blockedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BlockedUsersCompanion(')
          ..write('peerId: $peerId, ')
          ..write('blockedAt: $blockedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MessageReactionsTable extends MessageReactions
    with TableInfo<$MessageReactionsTable, ReactionEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MessageReactionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _messageIdMeta =
      const VerificationMeta('messageId');
  @override
  late final GeneratedColumn<String> messageId = GeneratedColumn<String>(
      'message_id', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES messages (id)'));
  static const VerificationMeta _senderIdMeta =
      const VerificationMeta('senderId');
  @override
  late final GeneratedColumn<String> senderId = GeneratedColumn<String>(
      'sender_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _emojiMeta = const VerificationMeta('emoji');
  @override
  late final GeneratedColumn<String> emoji = GeneratedColumn<String>(
      'emoji', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [id, messageId, senderId, emoji, createdAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'message_reactions';
  @override
  VerificationContext validateIntegrity(Insertable<ReactionEntry> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('message_id')) {
      context.handle(_messageIdMeta,
          messageId.isAcceptableOrUnknown(data['message_id']!, _messageIdMeta));
    } else if (isInserting) {
      context.missing(_messageIdMeta);
    }
    if (data.containsKey('sender_id')) {
      context.handle(_senderIdMeta,
          senderId.isAcceptableOrUnknown(data['sender_id']!, _senderIdMeta));
    } else if (isInserting) {
      context.missing(_senderIdMeta);
    }
    if (data.containsKey('emoji')) {
      context.handle(
          _emojiMeta, emoji.isAcceptableOrUnknown(data['emoji']!, _emojiMeta));
    } else if (isInserting) {
      context.missing(_emojiMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ReactionEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ReactionEntry(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      messageId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}message_id'])!,
      senderId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sender_id'])!,
      emoji: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}emoji'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
    );
  }

  @override
  $MessageReactionsTable createAlias(String alias) {
    return $MessageReactionsTable(attachedDatabase, alias);
  }
}

class ReactionEntry extends DataClass implements Insertable<ReactionEntry> {
  final String id;
  final String messageId;
  final String senderId;
  final String emoji;
  final DateTime createdAt;
  const ReactionEntry(
      {required this.id,
      required this.messageId,
      required this.senderId,
      required this.emoji,
      required this.createdAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['message_id'] = Variable<String>(messageId);
    map['sender_id'] = Variable<String>(senderId);
    map['emoji'] = Variable<String>(emoji);
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  MessageReactionsCompanion toCompanion(bool nullToAbsent) {
    return MessageReactionsCompanion(
      id: Value(id),
      messageId: Value(messageId),
      senderId: Value(senderId),
      emoji: Value(emoji),
      createdAt: Value(createdAt),
    );
  }

  factory ReactionEntry.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ReactionEntry(
      id: serializer.fromJson<String>(json['id']),
      messageId: serializer.fromJson<String>(json['messageId']),
      senderId: serializer.fromJson<String>(json['senderId']),
      emoji: serializer.fromJson<String>(json['emoji']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'messageId': serializer.toJson<String>(messageId),
      'senderId': serializer.toJson<String>(senderId),
      'emoji': serializer.toJson<String>(emoji),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  ReactionEntry copyWith(
          {String? id,
          String? messageId,
          String? senderId,
          String? emoji,
          DateTime? createdAt}) =>
      ReactionEntry(
        id: id ?? this.id,
        messageId: messageId ?? this.messageId,
        senderId: senderId ?? this.senderId,
        emoji: emoji ?? this.emoji,
        createdAt: createdAt ?? this.createdAt,
      );
  ReactionEntry copyWithCompanion(MessageReactionsCompanion data) {
    return ReactionEntry(
      id: data.id.present ? data.id.value : this.id,
      messageId: data.messageId.present ? data.messageId.value : this.messageId,
      senderId: data.senderId.present ? data.senderId.value : this.senderId,
      emoji: data.emoji.present ? data.emoji.value : this.emoji,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ReactionEntry(')
          ..write('id: $id, ')
          ..write('messageId: $messageId, ')
          ..write('senderId: $senderId, ')
          ..write('emoji: $emoji, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, messageId, senderId, emoji, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ReactionEntry &&
          other.id == this.id &&
          other.messageId == this.messageId &&
          other.senderId == this.senderId &&
          other.emoji == this.emoji &&
          other.createdAt == this.createdAt);
}

class MessageReactionsCompanion extends UpdateCompanion<ReactionEntry> {
  final Value<String> id;
  final Value<String> messageId;
  final Value<String> senderId;
  final Value<String> emoji;
  final Value<DateTime> createdAt;
  final Value<int> rowid;
  const MessageReactionsCompanion({
    this.id = const Value.absent(),
    this.messageId = const Value.absent(),
    this.senderId = const Value.absent(),
    this.emoji = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MessageReactionsCompanion.insert({
    required String id,
    required String messageId,
    required String senderId,
    required String emoji,
    required DateTime createdAt,
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        messageId = Value(messageId),
        senderId = Value(senderId),
        emoji = Value(emoji),
        createdAt = Value(createdAt);
  static Insertable<ReactionEntry> custom({
    Expression<String>? id,
    Expression<String>? messageId,
    Expression<String>? senderId,
    Expression<String>? emoji,
    Expression<DateTime>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (messageId != null) 'message_id': messageId,
      if (senderId != null) 'sender_id': senderId,
      if (emoji != null) 'emoji': emoji,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MessageReactionsCompanion copyWith(
      {Value<String>? id,
      Value<String>? messageId,
      Value<String>? senderId,
      Value<String>? emoji,
      Value<DateTime>? createdAt,
      Value<int>? rowid}) {
    return MessageReactionsCompanion(
      id: id ?? this.id,
      messageId: messageId ?? this.messageId,
      senderId: senderId ?? this.senderId,
      emoji: emoji ?? this.emoji,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (messageId.present) {
      map['message_id'] = Variable<String>(messageId.value);
    }
    if (senderId.present) {
      map['sender_id'] = Variable<String>(senderId.value);
    }
    if (emoji.present) {
      map['emoji'] = Variable<String>(emoji.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MessageReactionsCompanion(')
          ..write('id: $id, ')
          ..write('messageId: $messageId, ')
          ..write('senderId: $senderId, ')
          ..write('emoji: $emoji, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $UserProfilesTable userProfiles = $UserProfilesTable(this);
  late final $UserPhotosTable userPhotos = $UserPhotosTable(this);
  late final $DiscoveredPeersTable discoveredPeers =
      $DiscoveredPeersTable(this);
  late final $ConversationsTable conversations = $ConversationsTable(this);
  late final $MessagesTable messages = $MessagesTable(this);
  late final $AnchorDropsTable anchorDrops = $AnchorDropsTable(this);
  late final $BlockedUsersTable blockedUsers = $BlockedUsersTable(this);
  late final $MessageReactionsTable messageReactions =
      $MessageReactionsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
        userProfiles,
        userPhotos,
        discoveredPeers,
        conversations,
        messages,
        anchorDrops,
        blockedUsers,
        messageReactions
      ];
}

typedef $$UserProfilesTableCreateCompanionBuilder = UserProfilesCompanion
    Function({
  required String id,
  required String name,
  Value<int?> age,
  Value<String?> bio,
  Value<int?> position,
  Value<String?> interests,
  required DateTime createdAt,
  required DateTime updatedAt,
  Value<int> rowid,
});
typedef $$UserProfilesTableUpdateCompanionBuilder = UserProfilesCompanion
    Function({
  Value<String> id,
  Value<String> name,
  Value<int?> age,
  Value<String?> bio,
  Value<int?> position,
  Value<String?> interests,
  Value<DateTime> createdAt,
  Value<DateTime> updatedAt,
  Value<int> rowid,
});

final class $$UserProfilesTableReferences extends BaseReferences<_$AppDatabase,
    $UserProfilesTable, UserProfileEntry> {
  $$UserProfilesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$UserPhotosTable, List<UserPhotoEntry>>
      _userPhotosRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
          db.userPhotos,
          aliasName:
              $_aliasNameGenerator(db.userProfiles.id, db.userPhotos.userId));

  $$UserPhotosTableProcessedTableManager get userPhotosRefs {
    final manager = $$UserPhotosTableTableManager($_db, $_db.userPhotos)
        .filter((f) => f.userId.id($_item.id));

    final cache = $_typedResult.readTableOrNull(_userPhotosRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$UserProfilesTableFilterComposer
    extends Composer<_$AppDatabase, $UserProfilesTable> {
  $$UserProfilesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get age => $composableBuilder(
      column: $table.age, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get bio => $composableBuilder(
      column: $table.bio, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get position => $composableBuilder(
      column: $table.position, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get interests => $composableBuilder(
      column: $table.interests, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));

  Expression<bool> userPhotosRefs(
      Expression<bool> Function($$UserPhotosTableFilterComposer f) f) {
    final $$UserPhotosTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.userPhotos,
        getReferencedColumn: (t) => t.userId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$UserPhotosTableFilterComposer(
              $db: $db,
              $table: $db.userPhotos,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$UserProfilesTableOrderingComposer
    extends Composer<_$AppDatabase, $UserProfilesTable> {
  $$UserProfilesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get age => $composableBuilder(
      column: $table.age, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get bio => $composableBuilder(
      column: $table.bio, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get position => $composableBuilder(
      column: $table.position, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get interests => $composableBuilder(
      column: $table.interests, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$UserProfilesTableAnnotationComposer
    extends Composer<_$AppDatabase, $UserProfilesTable> {
  $$UserProfilesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get age =>
      $composableBuilder(column: $table.age, builder: (column) => column);

  GeneratedColumn<String> get bio =>
      $composableBuilder(column: $table.bio, builder: (column) => column);

  GeneratedColumn<int> get position =>
      $composableBuilder(column: $table.position, builder: (column) => column);

  GeneratedColumn<String> get interests =>
      $composableBuilder(column: $table.interests, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  Expression<T> userPhotosRefs<T extends Object>(
      Expression<T> Function($$UserPhotosTableAnnotationComposer a) f) {
    final $$UserPhotosTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.userPhotos,
        getReferencedColumn: (t) => t.userId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$UserPhotosTableAnnotationComposer(
              $db: $db,
              $table: $db.userPhotos,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$UserProfilesTableTableManager extends RootTableManager<
    _$AppDatabase,
    $UserProfilesTable,
    UserProfileEntry,
    $$UserProfilesTableFilterComposer,
    $$UserProfilesTableOrderingComposer,
    $$UserProfilesTableAnnotationComposer,
    $$UserProfilesTableCreateCompanionBuilder,
    $$UserProfilesTableUpdateCompanionBuilder,
    (UserProfileEntry, $$UserProfilesTableReferences),
    UserProfileEntry,
    PrefetchHooks Function({bool userPhotosRefs})> {
  $$UserProfilesTableTableManager(_$AppDatabase db, $UserProfilesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$UserProfilesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$UserProfilesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$UserProfilesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<int?> age = const Value.absent(),
            Value<String?> bio = const Value.absent(),
            Value<int?> position = const Value.absent(),
            Value<String?> interests = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> updatedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              UserProfilesCompanion(
            id: id,
            name: name,
            age: age,
            bio: bio,
            position: position,
            interests: interests,
            createdAt: createdAt,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String name,
            Value<int?> age = const Value.absent(),
            Value<String?> bio = const Value.absent(),
            Value<int?> position = const Value.absent(),
            Value<String?> interests = const Value.absent(),
            required DateTime createdAt,
            required DateTime updatedAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              UserProfilesCompanion.insert(
            id: id,
            name: name,
            age: age,
            bio: bio,
            position: position,
            interests: interests,
            createdAt: createdAt,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$UserProfilesTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({userPhotosRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (userPhotosRefs) db.userPhotos],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (userPhotosRefs)
                    await $_getPrefetchedData(
                        currentTable: table,
                        referencedTable: $$UserProfilesTableReferences
                            ._userPhotosRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$UserProfilesTableReferences(db, table, p0)
                                .userPhotosRefs,
                        referencedItemsForCurrentItem: (item,
                                referencedItems) =>
                            referencedItems.where((e) => e.userId == item.id),
                        typedResults: items)
                ];
              },
            );
          },
        ));
}

typedef $$UserProfilesTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $UserProfilesTable,
    UserProfileEntry,
    $$UserProfilesTableFilterComposer,
    $$UserProfilesTableOrderingComposer,
    $$UserProfilesTableAnnotationComposer,
    $$UserProfilesTableCreateCompanionBuilder,
    $$UserProfilesTableUpdateCompanionBuilder,
    (UserProfileEntry, $$UserProfilesTableReferences),
    UserProfileEntry,
    PrefetchHooks Function({bool userPhotosRefs})>;
typedef $$UserPhotosTableCreateCompanionBuilder = UserPhotosCompanion Function({
  required String id,
  required String userId,
  required String photoPath,
  required String thumbnailPath,
  Value<bool> isPrimary,
  required int orderIndex,
  required DateTime createdAt,
  Value<int> rowid,
});
typedef $$UserPhotosTableUpdateCompanionBuilder = UserPhotosCompanion Function({
  Value<String> id,
  Value<String> userId,
  Value<String> photoPath,
  Value<String> thumbnailPath,
  Value<bool> isPrimary,
  Value<int> orderIndex,
  Value<DateTime> createdAt,
  Value<int> rowid,
});

final class $$UserPhotosTableReferences
    extends BaseReferences<_$AppDatabase, $UserPhotosTable, UserPhotoEntry> {
  $$UserPhotosTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $UserProfilesTable _userIdTable(_$AppDatabase db) =>
      db.userProfiles.createAlias(
          $_aliasNameGenerator(db.userPhotos.userId, db.userProfiles.id));

  $$UserProfilesTableProcessedTableManager? get userId {
    if ($_item.userId == null) return null;
    final manager = $$UserProfilesTableTableManager($_db, $_db.userProfiles)
        .filter((f) => f.id($_item.userId!));
    final item = $_typedResult.readTableOrNull(_userIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$UserPhotosTableFilterComposer
    extends Composer<_$AppDatabase, $UserPhotosTable> {
  $$UserPhotosTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get photoPath => $composableBuilder(
      column: $table.photoPath, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get thumbnailPath => $composableBuilder(
      column: $table.thumbnailPath, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get isPrimary => $composableBuilder(
      column: $table.isPrimary, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get orderIndex => $composableBuilder(
      column: $table.orderIndex, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  $$UserProfilesTableFilterComposer get userId {
    final $$UserProfilesTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.userId,
        referencedTable: $db.userProfiles,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$UserProfilesTableFilterComposer(
              $db: $db,
              $table: $db.userProfiles,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$UserPhotosTableOrderingComposer
    extends Composer<_$AppDatabase, $UserPhotosTable> {
  $$UserPhotosTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get photoPath => $composableBuilder(
      column: $table.photoPath, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get thumbnailPath => $composableBuilder(
      column: $table.thumbnailPath,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get isPrimary => $composableBuilder(
      column: $table.isPrimary, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get orderIndex => $composableBuilder(
      column: $table.orderIndex, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  $$UserProfilesTableOrderingComposer get userId {
    final $$UserProfilesTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.userId,
        referencedTable: $db.userProfiles,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$UserProfilesTableOrderingComposer(
              $db: $db,
              $table: $db.userProfiles,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$UserPhotosTableAnnotationComposer
    extends Composer<_$AppDatabase, $UserPhotosTable> {
  $$UserPhotosTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get photoPath =>
      $composableBuilder(column: $table.photoPath, builder: (column) => column);

  GeneratedColumn<String> get thumbnailPath => $composableBuilder(
      column: $table.thumbnailPath, builder: (column) => column);

  GeneratedColumn<bool> get isPrimary =>
      $composableBuilder(column: $table.isPrimary, builder: (column) => column);

  GeneratedColumn<int> get orderIndex => $composableBuilder(
      column: $table.orderIndex, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  $$UserProfilesTableAnnotationComposer get userId {
    final $$UserProfilesTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.userId,
        referencedTable: $db.userProfiles,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$UserProfilesTableAnnotationComposer(
              $db: $db,
              $table: $db.userProfiles,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$UserPhotosTableTableManager extends RootTableManager<
    _$AppDatabase,
    $UserPhotosTable,
    UserPhotoEntry,
    $$UserPhotosTableFilterComposer,
    $$UserPhotosTableOrderingComposer,
    $$UserPhotosTableAnnotationComposer,
    $$UserPhotosTableCreateCompanionBuilder,
    $$UserPhotosTableUpdateCompanionBuilder,
    (UserPhotoEntry, $$UserPhotosTableReferences),
    UserPhotoEntry,
    PrefetchHooks Function({bool userId})> {
  $$UserPhotosTableTableManager(_$AppDatabase db, $UserPhotosTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$UserPhotosTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$UserPhotosTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$UserPhotosTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> userId = const Value.absent(),
            Value<String> photoPath = const Value.absent(),
            Value<String> thumbnailPath = const Value.absent(),
            Value<bool> isPrimary = const Value.absent(),
            Value<int> orderIndex = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              UserPhotosCompanion(
            id: id,
            userId: userId,
            photoPath: photoPath,
            thumbnailPath: thumbnailPath,
            isPrimary: isPrimary,
            orderIndex: orderIndex,
            createdAt: createdAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String userId,
            required String photoPath,
            required String thumbnailPath,
            Value<bool> isPrimary = const Value.absent(),
            required int orderIndex,
            required DateTime createdAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              UserPhotosCompanion.insert(
            id: id,
            userId: userId,
            photoPath: photoPath,
            thumbnailPath: thumbnailPath,
            isPrimary: isPrimary,
            orderIndex: orderIndex,
            createdAt: createdAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$UserPhotosTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({userId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (userId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.userId,
                    referencedTable:
                        $$UserPhotosTableReferences._userIdTable(db),
                    referencedColumn:
                        $$UserPhotosTableReferences._userIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$UserPhotosTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $UserPhotosTable,
    UserPhotoEntry,
    $$UserPhotosTableFilterComposer,
    $$UserPhotosTableOrderingComposer,
    $$UserPhotosTableAnnotationComposer,
    $$UserPhotosTableCreateCompanionBuilder,
    $$UserPhotosTableUpdateCompanionBuilder,
    (UserPhotoEntry, $$UserPhotosTableReferences),
    UserPhotoEntry,
    PrefetchHooks Function({bool userId})>;
typedef $$DiscoveredPeersTableCreateCompanionBuilder = DiscoveredPeersCompanion
    Function({
  required String peerId,
  Value<String?> userId,
  required String name,
  Value<int?> age,
  Value<String?> bio,
  Value<Uint8List?> thumbnailData,
  required DateTime lastSeenAt,
  Value<int?> rssi,
  Value<bool> isBlocked,
  Value<int?> position,
  Value<String?> interests,
  Value<int> rowid,
});
typedef $$DiscoveredPeersTableUpdateCompanionBuilder = DiscoveredPeersCompanion
    Function({
  Value<String> peerId,
  Value<String?> userId,
  Value<String> name,
  Value<int?> age,
  Value<String?> bio,
  Value<Uint8List?> thumbnailData,
  Value<DateTime> lastSeenAt,
  Value<int?> rssi,
  Value<bool> isBlocked,
  Value<int?> position,
  Value<String?> interests,
  Value<int> rowid,
});

final class $$DiscoveredPeersTableReferences extends BaseReferences<
    _$AppDatabase, $DiscoveredPeersTable, DiscoveredPeerEntry> {
  $$DiscoveredPeersTableReferences(
      super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$ConversationsTable, List<ConversationEntry>>
      _conversationsRefsTable(_$AppDatabase db) =>
          MultiTypedResultKey.fromTable(db.conversations,
              aliasName: $_aliasNameGenerator(
                  db.discoveredPeers.peerId, db.conversations.peerId));

  $$ConversationsTableProcessedTableManager get conversationsRefs {
    final manager = $$ConversationsTableTableManager($_db, $_db.conversations)
        .filter((f) => f.peerId.peerId($_item.peerId));

    final cache = $_typedResult.readTableOrNull(_conversationsRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$DiscoveredPeersTableFilterComposer
    extends Composer<_$AppDatabase, $DiscoveredPeersTable> {
  $$DiscoveredPeersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get peerId => $composableBuilder(
      column: $table.peerId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get userId => $composableBuilder(
      column: $table.userId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get age => $composableBuilder(
      column: $table.age, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get bio => $composableBuilder(
      column: $table.bio, builder: (column) => ColumnFilters(column));

  ColumnFilters<Uint8List> get thumbnailData => $composableBuilder(
      column: $table.thumbnailData, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get lastSeenAt => $composableBuilder(
      column: $table.lastSeenAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get rssi => $composableBuilder(
      column: $table.rssi, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get isBlocked => $composableBuilder(
      column: $table.isBlocked, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get position => $composableBuilder(
      column: $table.position, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get interests => $composableBuilder(
      column: $table.interests, builder: (column) => ColumnFilters(column));

  Expression<bool> conversationsRefs(
      Expression<bool> Function($$ConversationsTableFilterComposer f) f) {
    final $$ConversationsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.peerId,
        referencedTable: $db.conversations,
        getReferencedColumn: (t) => t.peerId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$ConversationsTableFilterComposer(
              $db: $db,
              $table: $db.conversations,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$DiscoveredPeersTableOrderingComposer
    extends Composer<_$AppDatabase, $DiscoveredPeersTable> {
  $$DiscoveredPeersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get peerId => $composableBuilder(
      column: $table.peerId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get userId => $composableBuilder(
      column: $table.userId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get age => $composableBuilder(
      column: $table.age, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get bio => $composableBuilder(
      column: $table.bio, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<Uint8List> get thumbnailData => $composableBuilder(
      column: $table.thumbnailData,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get lastSeenAt => $composableBuilder(
      column: $table.lastSeenAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get rssi => $composableBuilder(
      column: $table.rssi, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get isBlocked => $composableBuilder(
      column: $table.isBlocked, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get position => $composableBuilder(
      column: $table.position, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get interests => $composableBuilder(
      column: $table.interests, builder: (column) => ColumnOrderings(column));
}

class $$DiscoveredPeersTableAnnotationComposer
    extends Composer<_$AppDatabase, $DiscoveredPeersTable> {
  $$DiscoveredPeersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get peerId =>
      $composableBuilder(column: $table.peerId, builder: (column) => column);

  GeneratedColumn<String> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get age =>
      $composableBuilder(column: $table.age, builder: (column) => column);

  GeneratedColumn<String> get bio =>
      $composableBuilder(column: $table.bio, builder: (column) => column);

  GeneratedColumn<Uint8List> get thumbnailData => $composableBuilder(
      column: $table.thumbnailData, builder: (column) => column);

  GeneratedColumn<DateTime> get lastSeenAt => $composableBuilder(
      column: $table.lastSeenAt, builder: (column) => column);

  GeneratedColumn<int> get rssi =>
      $composableBuilder(column: $table.rssi, builder: (column) => column);

  GeneratedColumn<bool> get isBlocked =>
      $composableBuilder(column: $table.isBlocked, builder: (column) => column);

  GeneratedColumn<int> get position =>
      $composableBuilder(column: $table.position, builder: (column) => column);

  GeneratedColumn<String> get interests =>
      $composableBuilder(column: $table.interests, builder: (column) => column);

  Expression<T> conversationsRefs<T extends Object>(
      Expression<T> Function($$ConversationsTableAnnotationComposer a) f) {
    final $$ConversationsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.peerId,
        referencedTable: $db.conversations,
        getReferencedColumn: (t) => t.peerId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$ConversationsTableAnnotationComposer(
              $db: $db,
              $table: $db.conversations,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$DiscoveredPeersTableTableManager extends RootTableManager<
    _$AppDatabase,
    $DiscoveredPeersTable,
    DiscoveredPeerEntry,
    $$DiscoveredPeersTableFilterComposer,
    $$DiscoveredPeersTableOrderingComposer,
    $$DiscoveredPeersTableAnnotationComposer,
    $$DiscoveredPeersTableCreateCompanionBuilder,
    $$DiscoveredPeersTableUpdateCompanionBuilder,
    (DiscoveredPeerEntry, $$DiscoveredPeersTableReferences),
    DiscoveredPeerEntry,
    PrefetchHooks Function({bool conversationsRefs})> {
  $$DiscoveredPeersTableTableManager(
      _$AppDatabase db, $DiscoveredPeersTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DiscoveredPeersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DiscoveredPeersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DiscoveredPeersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> peerId = const Value.absent(),
            Value<String?> userId = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<int?> age = const Value.absent(),
            Value<String?> bio = const Value.absent(),
            Value<Uint8List?> thumbnailData = const Value.absent(),
            Value<DateTime> lastSeenAt = const Value.absent(),
            Value<int?> rssi = const Value.absent(),
            Value<bool> isBlocked = const Value.absent(),
            Value<int?> position = const Value.absent(),
            Value<String?> interests = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              DiscoveredPeersCompanion(
            peerId: peerId,
            userId: userId,
            name: name,
            age: age,
            bio: bio,
            thumbnailData: thumbnailData,
            lastSeenAt: lastSeenAt,
            rssi: rssi,
            isBlocked: isBlocked,
            position: position,
            interests: interests,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String peerId,
            Value<String?> userId = const Value.absent(),
            required String name,
            Value<int?> age = const Value.absent(),
            Value<String?> bio = const Value.absent(),
            Value<Uint8List?> thumbnailData = const Value.absent(),
            required DateTime lastSeenAt,
            Value<int?> rssi = const Value.absent(),
            Value<bool> isBlocked = const Value.absent(),
            Value<int?> position = const Value.absent(),
            Value<String?> interests = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              DiscoveredPeersCompanion.insert(
            peerId: peerId,
            userId: userId,
            name: name,
            age: age,
            bio: bio,
            thumbnailData: thumbnailData,
            lastSeenAt: lastSeenAt,
            rssi: rssi,
            isBlocked: isBlocked,
            position: position,
            interests: interests,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$DiscoveredPeersTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({conversationsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (conversationsRefs) db.conversations
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (conversationsRefs)
                    await $_getPrefetchedData(
                        currentTable: table,
                        referencedTable: $$DiscoveredPeersTableReferences
                            ._conversationsRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$DiscoveredPeersTableReferences(db, table, p0)
                                .conversationsRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.peerId == item.peerId),
                        typedResults: items)
                ];
              },
            );
          },
        ));
}

typedef $$DiscoveredPeersTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $DiscoveredPeersTable,
    DiscoveredPeerEntry,
    $$DiscoveredPeersTableFilterComposer,
    $$DiscoveredPeersTableOrderingComposer,
    $$DiscoveredPeersTableAnnotationComposer,
    $$DiscoveredPeersTableCreateCompanionBuilder,
    $$DiscoveredPeersTableUpdateCompanionBuilder,
    (DiscoveredPeerEntry, $$DiscoveredPeersTableReferences),
    DiscoveredPeerEntry,
    PrefetchHooks Function({bool conversationsRefs})>;
typedef $$ConversationsTableCreateCompanionBuilder = ConversationsCompanion
    Function({
  required String id,
  required String peerId,
  required DateTime createdAt,
  required DateTime updatedAt,
  Value<int> rowid,
});
typedef $$ConversationsTableUpdateCompanionBuilder = ConversationsCompanion
    Function({
  Value<String> id,
  Value<String> peerId,
  Value<DateTime> createdAt,
  Value<DateTime> updatedAt,
  Value<int> rowid,
});

final class $$ConversationsTableReferences extends BaseReferences<_$AppDatabase,
    $ConversationsTable, ConversationEntry> {
  $$ConversationsTableReferences(
      super.$_db, super.$_table, super.$_typedResult);

  static $DiscoveredPeersTable _peerIdTable(_$AppDatabase db) =>
      db.discoveredPeers.createAlias($_aliasNameGenerator(
          db.conversations.peerId, db.discoveredPeers.peerId));

  $$DiscoveredPeersTableProcessedTableManager? get peerId {
    if ($_item.peerId == null) return null;
    final manager =
        $$DiscoveredPeersTableTableManager($_db, $_db.discoveredPeers)
            .filter((f) => f.peerId($_item.peerId!));
    final item = $_typedResult.readTableOrNull(_peerIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }

  static MultiTypedResultKey<$MessagesTable, List<MessageEntry>>
      _messagesRefsTable(_$AppDatabase db) =>
          MultiTypedResultKey.fromTable(db.messages,
              aliasName: $_aliasNameGenerator(
                  db.conversations.id, db.messages.conversationId));

  $$MessagesTableProcessedTableManager get messagesRefs {
    final manager = $$MessagesTableTableManager($_db, $_db.messages)
        .filter((f) => f.conversationId.id($_item.id));

    final cache = $_typedResult.readTableOrNull(_messagesRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$ConversationsTableFilterComposer
    extends Composer<_$AppDatabase, $ConversationsTable> {
  $$ConversationsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));

  $$DiscoveredPeersTableFilterComposer get peerId {
    final $$DiscoveredPeersTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.peerId,
        referencedTable: $db.discoveredPeers,
        getReferencedColumn: (t) => t.peerId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$DiscoveredPeersTableFilterComposer(
              $db: $db,
              $table: $db.discoveredPeers,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  Expression<bool> messagesRefs(
      Expression<bool> Function($$MessagesTableFilterComposer f) f) {
    final $$MessagesTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.messages,
        getReferencedColumn: (t) => t.conversationId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$MessagesTableFilterComposer(
              $db: $db,
              $table: $db.messages,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$ConversationsTableOrderingComposer
    extends Composer<_$AppDatabase, $ConversationsTable> {
  $$ConversationsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));

  $$DiscoveredPeersTableOrderingComposer get peerId {
    final $$DiscoveredPeersTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.peerId,
        referencedTable: $db.discoveredPeers,
        getReferencedColumn: (t) => t.peerId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$DiscoveredPeersTableOrderingComposer(
              $db: $db,
              $table: $db.discoveredPeers,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$ConversationsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ConversationsTable> {
  $$ConversationsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  $$DiscoveredPeersTableAnnotationComposer get peerId {
    final $$DiscoveredPeersTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.peerId,
        referencedTable: $db.discoveredPeers,
        getReferencedColumn: (t) => t.peerId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$DiscoveredPeersTableAnnotationComposer(
              $db: $db,
              $table: $db.discoveredPeers,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  Expression<T> messagesRefs<T extends Object>(
      Expression<T> Function($$MessagesTableAnnotationComposer a) f) {
    final $$MessagesTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.messages,
        getReferencedColumn: (t) => t.conversationId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$MessagesTableAnnotationComposer(
              $db: $db,
              $table: $db.messages,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$ConversationsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $ConversationsTable,
    ConversationEntry,
    $$ConversationsTableFilterComposer,
    $$ConversationsTableOrderingComposer,
    $$ConversationsTableAnnotationComposer,
    $$ConversationsTableCreateCompanionBuilder,
    $$ConversationsTableUpdateCompanionBuilder,
    (ConversationEntry, $$ConversationsTableReferences),
    ConversationEntry,
    PrefetchHooks Function({bool peerId, bool messagesRefs})> {
  $$ConversationsTableTableManager(_$AppDatabase db, $ConversationsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ConversationsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ConversationsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ConversationsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> peerId = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> updatedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              ConversationsCompanion(
            id: id,
            peerId: peerId,
            createdAt: createdAt,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String peerId,
            required DateTime createdAt,
            required DateTime updatedAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              ConversationsCompanion.insert(
            id: id,
            peerId: peerId,
            createdAt: createdAt,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$ConversationsTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({peerId = false, messagesRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (messagesRefs) db.messages],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (peerId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.peerId,
                    referencedTable:
                        $$ConversationsTableReferences._peerIdTable(db),
                    referencedColumn:
                        $$ConversationsTableReferences._peerIdTable(db).peerId,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [
                  if (messagesRefs)
                    await $_getPrefetchedData(
                        currentTable: table,
                        referencedTable: $$ConversationsTableReferences
                            ._messagesRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$ConversationsTableReferences(db, table, p0)
                                .messagesRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.conversationId == item.id),
                        typedResults: items)
                ];
              },
            );
          },
        ));
}

typedef $$ConversationsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $ConversationsTable,
    ConversationEntry,
    $$ConversationsTableFilterComposer,
    $$ConversationsTableOrderingComposer,
    $$ConversationsTableAnnotationComposer,
    $$ConversationsTableCreateCompanionBuilder,
    $$ConversationsTableUpdateCompanionBuilder,
    (ConversationEntry, $$ConversationsTableReferences),
    ConversationEntry,
    PrefetchHooks Function({bool peerId, bool messagesRefs})>;
typedef $$MessagesTableCreateCompanionBuilder = MessagesCompanion Function({
  required String id,
  required String conversationId,
  required String senderId,
  required MessageContentType contentType,
  Value<String?> textContent,
  Value<String?> photoPath,
  required MessageStatus status,
  required DateTime createdAt,
  Value<int> rowid,
});
typedef $$MessagesTableUpdateCompanionBuilder = MessagesCompanion Function({
  Value<String> id,
  Value<String> conversationId,
  Value<String> senderId,
  Value<MessageContentType> contentType,
  Value<String?> textContent,
  Value<String?> photoPath,
  Value<MessageStatus> status,
  Value<DateTime> createdAt,
  Value<int> rowid,
});

final class $$MessagesTableReferences
    extends BaseReferences<_$AppDatabase, $MessagesTable, MessageEntry> {
  $$MessagesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $ConversationsTable _conversationIdTable(_$AppDatabase db) =>
      db.conversations.createAlias($_aliasNameGenerator(
          db.messages.conversationId, db.conversations.id));

  $$ConversationsTableProcessedTableManager? get conversationId {
    if ($_item.conversationId == null) return null;
    final manager = $$ConversationsTableTableManager($_db, $_db.conversations)
        .filter((f) => f.id($_item.conversationId!));
    final item = $_typedResult.readTableOrNull(_conversationIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }

  static MultiTypedResultKey<$MessageReactionsTable, List<ReactionEntry>>
      _messageReactionsRefsTable(_$AppDatabase db) =>
          MultiTypedResultKey.fromTable(db.messageReactions,
              aliasName: $_aliasNameGenerator(
                  db.messages.id, db.messageReactions.messageId));

  $$MessageReactionsTableProcessedTableManager get messageReactionsRefs {
    final manager =
        $$MessageReactionsTableTableManager($_db, $_db.messageReactions)
            .filter((f) => f.messageId.id($_item.id));

    final cache =
        $_typedResult.readTableOrNull(_messageReactionsRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$MessagesTableFilterComposer
    extends Composer<_$AppDatabase, $MessagesTable> {
  $$MessagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get senderId => $composableBuilder(
      column: $table.senderId, builder: (column) => ColumnFilters(column));

  ColumnWithTypeConverterFilters<MessageContentType, MessageContentType, String>
      get contentType => $composableBuilder(
          column: $table.contentType,
          builder: (column) => ColumnWithTypeConverterFilters(column));

  ColumnFilters<String> get textContent => $composableBuilder(
      column: $table.textContent, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get photoPath => $composableBuilder(
      column: $table.photoPath, builder: (column) => ColumnFilters(column));

  ColumnWithTypeConverterFilters<MessageStatus, MessageStatus, String>
      get status => $composableBuilder(
          column: $table.status,
          builder: (column) => ColumnWithTypeConverterFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  $$ConversationsTableFilterComposer get conversationId {
    final $$ConversationsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.conversationId,
        referencedTable: $db.conversations,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$ConversationsTableFilterComposer(
              $db: $db,
              $table: $db.conversations,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  Expression<bool> messageReactionsRefs(
      Expression<bool> Function($$MessageReactionsTableFilterComposer f) f) {
    final $$MessageReactionsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.messageReactions,
        getReferencedColumn: (t) => t.messageId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$MessageReactionsTableFilterComposer(
              $db: $db,
              $table: $db.messageReactions,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$MessagesTableOrderingComposer
    extends Composer<_$AppDatabase, $MessagesTable> {
  $$MessagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get senderId => $composableBuilder(
      column: $table.senderId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get contentType => $composableBuilder(
      column: $table.contentType, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get textContent => $composableBuilder(
      column: $table.textContent, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get photoPath => $composableBuilder(
      column: $table.photoPath, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get status => $composableBuilder(
      column: $table.status, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  $$ConversationsTableOrderingComposer get conversationId {
    final $$ConversationsTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.conversationId,
        referencedTable: $db.conversations,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$ConversationsTableOrderingComposer(
              $db: $db,
              $table: $db.conversations,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$MessagesTableAnnotationComposer
    extends Composer<_$AppDatabase, $MessagesTable> {
  $$MessagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get senderId =>
      $composableBuilder(column: $table.senderId, builder: (column) => column);

  GeneratedColumnWithTypeConverter<MessageContentType, String>
      get contentType => $composableBuilder(
          column: $table.contentType, builder: (column) => column);

  GeneratedColumn<String> get textContent => $composableBuilder(
      column: $table.textContent, builder: (column) => column);

  GeneratedColumn<String> get photoPath =>
      $composableBuilder(column: $table.photoPath, builder: (column) => column);

  GeneratedColumnWithTypeConverter<MessageStatus, String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  $$ConversationsTableAnnotationComposer get conversationId {
    final $$ConversationsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.conversationId,
        referencedTable: $db.conversations,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$ConversationsTableAnnotationComposer(
              $db: $db,
              $table: $db.conversations,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  Expression<T> messageReactionsRefs<T extends Object>(
      Expression<T> Function($$MessageReactionsTableAnnotationComposer a) f) {
    final $$MessageReactionsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.messageReactions,
        getReferencedColumn: (t) => t.messageId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$MessageReactionsTableAnnotationComposer(
              $db: $db,
              $table: $db.messageReactions,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$MessagesTableTableManager extends RootTableManager<
    _$AppDatabase,
    $MessagesTable,
    MessageEntry,
    $$MessagesTableFilterComposer,
    $$MessagesTableOrderingComposer,
    $$MessagesTableAnnotationComposer,
    $$MessagesTableCreateCompanionBuilder,
    $$MessagesTableUpdateCompanionBuilder,
    (MessageEntry, $$MessagesTableReferences),
    MessageEntry,
    PrefetchHooks Function({bool conversationId, bool messageReactionsRefs})> {
  $$MessagesTableTableManager(_$AppDatabase db, $MessagesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MessagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MessagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MessagesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> conversationId = const Value.absent(),
            Value<String> senderId = const Value.absent(),
            Value<MessageContentType> contentType = const Value.absent(),
            Value<String?> textContent = const Value.absent(),
            Value<String?> photoPath = const Value.absent(),
            Value<MessageStatus> status = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              MessagesCompanion(
            id: id,
            conversationId: conversationId,
            senderId: senderId,
            contentType: contentType,
            textContent: textContent,
            photoPath: photoPath,
            status: status,
            createdAt: createdAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String conversationId,
            required String senderId,
            required MessageContentType contentType,
            Value<String?> textContent = const Value.absent(),
            Value<String?> photoPath = const Value.absent(),
            required MessageStatus status,
            required DateTime createdAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              MessagesCompanion.insert(
            id: id,
            conversationId: conversationId,
            senderId: senderId,
            contentType: contentType,
            textContent: textContent,
            photoPath: photoPath,
            status: status,
            createdAt: createdAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) =>
                  (e.readTable(table), $$MessagesTableReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: (
              {conversationId = false, messageReactionsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (messageReactionsRefs) db.messageReactions
              ],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (conversationId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.conversationId,
                    referencedTable:
                        $$MessagesTableReferences._conversationIdTable(db),
                    referencedColumn:
                        $$MessagesTableReferences._conversationIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [
                  if (messageReactionsRefs)
                    await $_getPrefetchedData(
                        currentTable: table,
                        referencedTable: $$MessagesTableReferences
                            ._messageReactionsRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$MessagesTableReferences(db, table, p0)
                                .messageReactionsRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.messageId == item.id),
                        typedResults: items)
                ];
              },
            );
          },
        ));
}

typedef $$MessagesTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $MessagesTable,
    MessageEntry,
    $$MessagesTableFilterComposer,
    $$MessagesTableOrderingComposer,
    $$MessagesTableAnnotationComposer,
    $$MessagesTableCreateCompanionBuilder,
    $$MessagesTableUpdateCompanionBuilder,
    (MessageEntry, $$MessagesTableReferences),
    MessageEntry,
    PrefetchHooks Function({bool conversationId, bool messageReactionsRefs})>;
typedef $$AnchorDropsTableCreateCompanionBuilder = AnchorDropsCompanion
    Function({
  required String id,
  required String peerId,
  required String peerName,
  required AnchorDropDirection direction,
  required DateTime droppedAt,
  Value<int> rowid,
});
typedef $$AnchorDropsTableUpdateCompanionBuilder = AnchorDropsCompanion
    Function({
  Value<String> id,
  Value<String> peerId,
  Value<String> peerName,
  Value<AnchorDropDirection> direction,
  Value<DateTime> droppedAt,
  Value<int> rowid,
});

class $$AnchorDropsTableFilterComposer
    extends Composer<_$AppDatabase, $AnchorDropsTable> {
  $$AnchorDropsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get peerId => $composableBuilder(
      column: $table.peerId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get peerName => $composableBuilder(
      column: $table.peerName, builder: (column) => ColumnFilters(column));

  ColumnWithTypeConverterFilters<AnchorDropDirection, AnchorDropDirection,
          String>
      get direction => $composableBuilder(
          column: $table.direction,
          builder: (column) => ColumnWithTypeConverterFilters(column));

  ColumnFilters<DateTime> get droppedAt => $composableBuilder(
      column: $table.droppedAt, builder: (column) => ColumnFilters(column));
}

class $$AnchorDropsTableOrderingComposer
    extends Composer<_$AppDatabase, $AnchorDropsTable> {
  $$AnchorDropsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get peerId => $composableBuilder(
      column: $table.peerId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get peerName => $composableBuilder(
      column: $table.peerName, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get direction => $composableBuilder(
      column: $table.direction, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get droppedAt => $composableBuilder(
      column: $table.droppedAt, builder: (column) => ColumnOrderings(column));
}

class $$AnchorDropsTableAnnotationComposer
    extends Composer<_$AppDatabase, $AnchorDropsTable> {
  $$AnchorDropsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get peerId =>
      $composableBuilder(column: $table.peerId, builder: (column) => column);

  GeneratedColumn<String> get peerName =>
      $composableBuilder(column: $table.peerName, builder: (column) => column);

  GeneratedColumnWithTypeConverter<AnchorDropDirection, String> get direction =>
      $composableBuilder(column: $table.direction, builder: (column) => column);

  GeneratedColumn<DateTime> get droppedAt =>
      $composableBuilder(column: $table.droppedAt, builder: (column) => column);
}

class $$AnchorDropsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $AnchorDropsTable,
    AnchorDropEntry,
    $$AnchorDropsTableFilterComposer,
    $$AnchorDropsTableOrderingComposer,
    $$AnchorDropsTableAnnotationComposer,
    $$AnchorDropsTableCreateCompanionBuilder,
    $$AnchorDropsTableUpdateCompanionBuilder,
    (
      AnchorDropEntry,
      BaseReferences<_$AppDatabase, $AnchorDropsTable, AnchorDropEntry>
    ),
    AnchorDropEntry,
    PrefetchHooks Function()> {
  $$AnchorDropsTableTableManager(_$AppDatabase db, $AnchorDropsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AnchorDropsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AnchorDropsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AnchorDropsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> peerId = const Value.absent(),
            Value<String> peerName = const Value.absent(),
            Value<AnchorDropDirection> direction = const Value.absent(),
            Value<DateTime> droppedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              AnchorDropsCompanion(
            id: id,
            peerId: peerId,
            peerName: peerName,
            direction: direction,
            droppedAt: droppedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String peerId,
            required String peerName,
            required AnchorDropDirection direction,
            required DateTime droppedAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              AnchorDropsCompanion.insert(
            id: id,
            peerId: peerId,
            peerName: peerName,
            direction: direction,
            droppedAt: droppedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$AnchorDropsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $AnchorDropsTable,
    AnchorDropEntry,
    $$AnchorDropsTableFilterComposer,
    $$AnchorDropsTableOrderingComposer,
    $$AnchorDropsTableAnnotationComposer,
    $$AnchorDropsTableCreateCompanionBuilder,
    $$AnchorDropsTableUpdateCompanionBuilder,
    (
      AnchorDropEntry,
      BaseReferences<_$AppDatabase, $AnchorDropsTable, AnchorDropEntry>
    ),
    AnchorDropEntry,
    PrefetchHooks Function()>;
typedef $$BlockedUsersTableCreateCompanionBuilder = BlockedUsersCompanion
    Function({
  required String peerId,
  required DateTime blockedAt,
  Value<int> rowid,
});
typedef $$BlockedUsersTableUpdateCompanionBuilder = BlockedUsersCompanion
    Function({
  Value<String> peerId,
  Value<DateTime> blockedAt,
  Value<int> rowid,
});

class $$BlockedUsersTableFilterComposer
    extends Composer<_$AppDatabase, $BlockedUsersTable> {
  $$BlockedUsersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get peerId => $composableBuilder(
      column: $table.peerId, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get blockedAt => $composableBuilder(
      column: $table.blockedAt, builder: (column) => ColumnFilters(column));
}

class $$BlockedUsersTableOrderingComposer
    extends Composer<_$AppDatabase, $BlockedUsersTable> {
  $$BlockedUsersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get peerId => $composableBuilder(
      column: $table.peerId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get blockedAt => $composableBuilder(
      column: $table.blockedAt, builder: (column) => ColumnOrderings(column));
}

class $$BlockedUsersTableAnnotationComposer
    extends Composer<_$AppDatabase, $BlockedUsersTable> {
  $$BlockedUsersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get peerId =>
      $composableBuilder(column: $table.peerId, builder: (column) => column);

  GeneratedColumn<DateTime> get blockedAt =>
      $composableBuilder(column: $table.blockedAt, builder: (column) => column);
}

class $$BlockedUsersTableTableManager extends RootTableManager<
    _$AppDatabase,
    $BlockedUsersTable,
    BlockedUserEntry,
    $$BlockedUsersTableFilterComposer,
    $$BlockedUsersTableOrderingComposer,
    $$BlockedUsersTableAnnotationComposer,
    $$BlockedUsersTableCreateCompanionBuilder,
    $$BlockedUsersTableUpdateCompanionBuilder,
    (
      BlockedUserEntry,
      BaseReferences<_$AppDatabase, $BlockedUsersTable, BlockedUserEntry>
    ),
    BlockedUserEntry,
    PrefetchHooks Function()> {
  $$BlockedUsersTableTableManager(_$AppDatabase db, $BlockedUsersTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BlockedUsersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$BlockedUsersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$BlockedUsersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> peerId = const Value.absent(),
            Value<DateTime> blockedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              BlockedUsersCompanion(
            peerId: peerId,
            blockedAt: blockedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String peerId,
            required DateTime blockedAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              BlockedUsersCompanion.insert(
            peerId: peerId,
            blockedAt: blockedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$BlockedUsersTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $BlockedUsersTable,
    BlockedUserEntry,
    $$BlockedUsersTableFilterComposer,
    $$BlockedUsersTableOrderingComposer,
    $$BlockedUsersTableAnnotationComposer,
    $$BlockedUsersTableCreateCompanionBuilder,
    $$BlockedUsersTableUpdateCompanionBuilder,
    (
      BlockedUserEntry,
      BaseReferences<_$AppDatabase, $BlockedUsersTable, BlockedUserEntry>
    ),
    BlockedUserEntry,
    PrefetchHooks Function()>;
typedef $$MessageReactionsTableCreateCompanionBuilder
    = MessageReactionsCompanion Function({
  required String id,
  required String messageId,
  required String senderId,
  required String emoji,
  required DateTime createdAt,
  Value<int> rowid,
});
typedef $$MessageReactionsTableUpdateCompanionBuilder
    = MessageReactionsCompanion Function({
  Value<String> id,
  Value<String> messageId,
  Value<String> senderId,
  Value<String> emoji,
  Value<DateTime> createdAt,
  Value<int> rowid,
});

final class $$MessageReactionsTableReferences extends BaseReferences<
    _$AppDatabase, $MessageReactionsTable, ReactionEntry> {
  $$MessageReactionsTableReferences(
      super.$_db, super.$_table, super.$_typedResult);

  static $MessagesTable _messageIdTable(_$AppDatabase db) =>
      db.messages.createAlias(
          $_aliasNameGenerator(db.messageReactions.messageId, db.messages.id));

  $$MessagesTableProcessedTableManager? get messageId {
    if ($_item.messageId == null) return null;
    final manager = $$MessagesTableTableManager($_db, $_db.messages)
        .filter((f) => f.id($_item.messageId!));
    final item = $_typedResult.readTableOrNull(_messageIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$MessageReactionsTableFilterComposer
    extends Composer<_$AppDatabase, $MessageReactionsTable> {
  $$MessageReactionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get senderId => $composableBuilder(
      column: $table.senderId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get emoji => $composableBuilder(
      column: $table.emoji, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  $$MessagesTableFilterComposer get messageId {
    final $$MessagesTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.messageId,
        referencedTable: $db.messages,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$MessagesTableFilterComposer(
              $db: $db,
              $table: $db.messages,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$MessageReactionsTableOrderingComposer
    extends Composer<_$AppDatabase, $MessageReactionsTable> {
  $$MessageReactionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get senderId => $composableBuilder(
      column: $table.senderId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get emoji => $composableBuilder(
      column: $table.emoji, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  $$MessagesTableOrderingComposer get messageId {
    final $$MessagesTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.messageId,
        referencedTable: $db.messages,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$MessagesTableOrderingComposer(
              $db: $db,
              $table: $db.messages,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$MessageReactionsTableAnnotationComposer
    extends Composer<_$AppDatabase, $MessageReactionsTable> {
  $$MessageReactionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get senderId =>
      $composableBuilder(column: $table.senderId, builder: (column) => column);

  GeneratedColumn<String> get emoji =>
      $composableBuilder(column: $table.emoji, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  $$MessagesTableAnnotationComposer get messageId {
    final $$MessagesTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.messageId,
        referencedTable: $db.messages,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$MessagesTableAnnotationComposer(
              $db: $db,
              $table: $db.messages,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$MessageReactionsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $MessageReactionsTable,
    ReactionEntry,
    $$MessageReactionsTableFilterComposer,
    $$MessageReactionsTableOrderingComposer,
    $$MessageReactionsTableAnnotationComposer,
    $$MessageReactionsTableCreateCompanionBuilder,
    $$MessageReactionsTableUpdateCompanionBuilder,
    (ReactionEntry, $$MessageReactionsTableReferences),
    ReactionEntry,
    PrefetchHooks Function({bool messageId})> {
  $$MessageReactionsTableTableManager(
      _$AppDatabase db, $MessageReactionsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MessageReactionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MessageReactionsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MessageReactionsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> messageId = const Value.absent(),
            Value<String> senderId = const Value.absent(),
            Value<String> emoji = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              MessageReactionsCompanion(
            id: id,
            messageId: messageId,
            senderId: senderId,
            emoji: emoji,
            createdAt: createdAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String messageId,
            required String senderId,
            required String emoji,
            required DateTime createdAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              MessageReactionsCompanion.insert(
            id: id,
            messageId: messageId,
            senderId: senderId,
            emoji: emoji,
            createdAt: createdAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$MessageReactionsTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({messageId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (messageId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.messageId,
                    referencedTable:
                        $$MessageReactionsTableReferences._messageIdTable(db),
                    referencedColumn: $$MessageReactionsTableReferences
                        ._messageIdTable(db)
                        .id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$MessageReactionsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $MessageReactionsTable,
    ReactionEntry,
    $$MessageReactionsTableFilterComposer,
    $$MessageReactionsTableOrderingComposer,
    $$MessageReactionsTableAnnotationComposer,
    $$MessageReactionsTableCreateCompanionBuilder,
    $$MessageReactionsTableUpdateCompanionBuilder,
    (ReactionEntry, $$MessageReactionsTableReferences),
    ReactionEntry,
    PrefetchHooks Function({bool messageId})>;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$UserProfilesTableTableManager get userProfiles =>
      $$UserProfilesTableTableManager(_db, _db.userProfiles);
  $$UserPhotosTableTableManager get userPhotos =>
      $$UserPhotosTableTableManager(_db, _db.userPhotos);
  $$DiscoveredPeersTableTableManager get discoveredPeers =>
      $$DiscoveredPeersTableTableManager(_db, _db.discoveredPeers);
  $$ConversationsTableTableManager get conversations =>
      $$ConversationsTableTableManager(_db, _db.conversations);
  $$MessagesTableTableManager get messages =>
      $$MessagesTableTableManager(_db, _db.messages);
  $$AnchorDropsTableTableManager get anchorDrops =>
      $$AnchorDropsTableTableManager(_db, _db.anchorDrops);
  $$BlockedUsersTableTableManager get blockedUsers =>
      $$BlockedUsersTableTableManager(_db, _db.blockedUsers);
  $$MessageReactionsTableTableManager get messageReactions =>
      $$MessageReactionsTableTableManager(_db, _db.messageReactions);
}
