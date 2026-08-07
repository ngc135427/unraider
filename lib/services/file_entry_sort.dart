import 'unraid_client.dart';

enum FileEntrySort {
  nameAscending,
  nameDescending,
  modifiedNewest,
  modifiedOldest,
  sizeLargest,
  sizeSmallest,
}

List<UnraidFileEntry> sortFileEntries(
  Iterable<UnraidFileEntry> entries,
  FileEntrySort sort,
) {
  final result = entries.toList(growable: false);
  result.sort((left, right) {
    if (left.isDirectory != right.isDirectory) {
      return left.isDirectory ? -1 : 1;
    }

    final comparison = switch (sort) {
      FileEntrySort.nameAscending => left.nameLower.compareTo(right.nameLower),
      FileEntrySort.nameDescending => right.nameLower.compareTo(left.nameLower),
      FileEntrySort.modifiedNewest =>
        _compareModified(left, right, newest: true),
      FileEntrySort.modifiedOldest =>
        _compareModified(left, right, newest: false),
      FileEntrySort.sizeLargest => right.sizeBytes.compareTo(left.sizeBytes),
      FileEntrySort.sizeSmallest => left.sizeBytes.compareTo(right.sizeBytes),
    };
    if (comparison != 0) {
      return comparison;
    }
    return left.nameLower.compareTo(right.nameLower);
  });
  return result;
}

int _compareModified(
  UnraidFileEntry left,
  UnraidFileEntry right, {
  required bool newest,
}) {
  final leftDate = left.modifiedDate;
  final rightDate = right.modifiedDate;
  if (leftDate == null || rightDate == null) {
    if (leftDate == null && rightDate == null) {
      return 0;
    }
    return leftDate == null ? 1 : -1;
  }
  return newest ? rightDate.compareTo(leftDate) : leftDate.compareTo(rightDate);
}
