import 'package:diktafon/data/db/database.dart';
import 'package:diktafon/data/repositories/settings_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The reading-order preference: newest first until asked otherwise (the
/// fork's default — upstream ships tape order), and remembered once asked.
void main() {
  test('newest-first is on by default here, and persists', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final settings = SettingsRepository(db);

    expect((await settings.get()).newestFirst, isTrue);

    await settings.setNewestFirst(true);
    expect((await settings.get()).newestFirst, isTrue);
    expect((await settings.watch().first).newestFirst, isTrue);

    await settings.setNewestFirst(false);
    expect((await settings.get()).newestFirst, isFalse);
  });
}
