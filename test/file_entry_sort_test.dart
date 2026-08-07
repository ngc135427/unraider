import 'package:flutter_test/flutter_test.dart';
import 'package:unraider/services/file_entry_sort.dart';
import 'package:unraider/services/unraid_client.dart';

void main() {
  UnraidFileEntry entry(
    String name, {
    bool directory = false,
    int size = 0,
    DateTime? modified,
  }) {
    return UnraidFileEntry(
      name: name,
      path: '/mnt/user/share/$name',
      isDirectory: directory,
      sizeBytes: size,
      size: '$size B',
      modified: modified?.toIso8601String() ?? '',
      modifiedDate: modified,
    );
  }

  final old = DateTime.utc(2025);
  final recent = DateTime.utc(2026);
  late List<UnraidFileEntry> entries;

  setUp(() {
    entries = [
      entry('z-file.mp4', size: 20, modified: old),
      entry('b-folder', directory: true, modified: old),
      entry('a-file.mp4', size: 10, modified: recent),
      entry('a-folder', directory: true, modified: recent),
    ];
  });

  test('keeps folders first while sorting names', () {
    expect(
      sortFileEntries(entries, FileEntrySort.nameAscending)
          .map((item) => item.name),
      ['a-folder', 'b-folder', 'a-file.mp4', 'z-file.mp4'],
    );
    expect(
      sortFileEntries(entries, FileEntrySort.nameDescending)
          .map((item) => item.name),
      ['b-folder', 'a-folder', 'z-file.mp4', 'a-file.mp4'],
    );
  });

  test('sorts modified time and size within each entry kind', () {
    expect(
      sortFileEntries(entries, FileEntrySort.modifiedNewest)
          .map((item) => item.name),
      ['a-folder', 'b-folder', 'a-file.mp4', 'z-file.mp4'],
    );
    expect(
      sortFileEntries(entries, FileEntrySort.sizeLargest)
          .map((item) => item.name),
      ['a-folder', 'b-folder', 'z-file.mp4', 'a-file.mp4'],
    );
  });
}
