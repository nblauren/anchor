import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../../core/constants/app_constants.dart';

part 'database.g.dart';

/// User profiles table
class UserProfiles extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get age => integer()();
  TextColumn get bio => text().nullable()();
  TextColumn get photoUrls => text()(); // JSON encoded list
  TextColumn get interests => text()(); // JSON encoded list
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  BoolColumn get isOwnProfile => boolean().withDefault(const Constant(false))();
  DateTimeColumn get lastSeenAt => dateTime().nullable()();
  TextColumn get bleIdentifier => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Chat messages table
class ChatMessages extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId => text()();
  TextColumn get senderId => text()();
  TextColumn get receiverId => text()();
  TextColumn get content => text()();
  DateTimeColumn get timestamp => dateTime()();
  BoolColumn get isDelivered => boolean().withDefault(const Constant(false))();
  BoolColumn get isRead => boolean().withDefault(const Constant(false))();
  BoolColumn get isSentByMe => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Conversations table
class Conversations extends Table {
  TextColumn get id => text()();
  TextColumn get participantId => text()();
  TextColumn get participantName => text()();
  TextColumn get participantPhotoUrl => text().nullable()();
  IntColumn get unreadCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [UserProfiles, ChatMessages, Conversations])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => AppConstants.databaseVersion;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        await m.createAll();
      },
      onUpgrade: (Migrator m, int from, int to) async {
        // Handle future migrations here
      },
    );
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, AppConstants.databaseName));
    return NativeDatabase.createInBackground(file);
  });
}
