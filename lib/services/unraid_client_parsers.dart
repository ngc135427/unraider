part of 'unraid_client.dart';

/// Large Docker/VM HTML payloads are cheaper to regex off the UI isolate.
const _managementParseIsolateThresholdBytes = 16 * 1024;

@visibleForTesting
List<UnraidManagementItem> parseDockerItems(String body) {
  return _parseDockerItems(body);
}

@visibleForTesting
List<UnraidManagementItem> parseVmItems(String body) {
  return _parseVmItems(body);
}

List<UnraidManagementItem> _parseDockerItems(String body) {
  return _managementItemsFromRows(_parseDockerItemRows(body));
}

List<UnraidManagementItem> _parseVmItems(String body) {
  return _managementItemsFromRows(_parseVmItemRows(body));
}

Future<List<UnraidManagementItem>> _parseDockerItemsAsync(String body) {
  return _parseManagementItemsAsync(body, _parseDockerItemRows);
}

Future<List<UnraidManagementItem>> _parseVmItemsAsync(String body) {
  return _parseManagementItemsAsync(body, _parseVmItemRows);
}

Future<List<UnraidManagementItem>> _parseManagementItemsAsync(
  String body,
  List<List<Object?>> Function(String body) parseRows,
) async {
  if (body.length < _managementParseIsolateThresholdBytes) {
    return _managementItemsFromRows(parseRows(body));
  }
  final rows = await Isolate.run(() => parseRows(body));
  return _managementItemsFromRows(rows);
}

final _dockerPushRegex = RegExp(
  r'''docker\.push\(\{name:'((?:\\'|[^'])*)',id:'([^']*)',state:(\d+),pause:(\d+),update:(\d+)''',
);
final _kvmStateRegex =
    RegExp(r'''kvm\.push\(\{id:'([^']*)',state:'([^']*)'\}\);''');
final _vmContextRegex = RegExp(r"addVMContext\('((?:\\'|[^'])*)','([^']*)'");

/// Row layout: id, title, status, description, typeIndex, detail, tags.
List<List<Object?>> _parseDockerItemRows(String body) {
  final rows = <List<Object?>>[];
  final nul = body.indexOf('\u0000');
  final script = nul >= 0 ? body.substring(nul + 1) : body;

  for (final match in _dockerPushRegex.allMatches(script)) {
    final name = _decodeJsString(match.group(1) ?? '');
    final id = match.group(2) ?? name;
    final isRunning = match.group(3) == '1';
    final isPaused = match.group(4) == '1';
    final hasUpdate = match.group(5) == '1';
    final status = isPaused
        ? '已暂停'
        : isRunning
            ? '运行中'
            : '已停止';
    rows.add(<Object?>[
      id,
      name,
      status,
      'Docker 容器',
      ManagementItemType.docker.index,
      id,
      <String>[if (hasUpdate) '有更新'],
    ]);
  }
  return rows;
}

List<List<Object?>> _parseVmItemRows(String body) {
  final parts = body.split('\u0000');
  final html = parts.isNotEmpty ? parts.first : body;
  final script = parts.length > 1 ? parts.last : body;
  final states = <String, String>{};
  for (final match in _kvmStateRegex.allMatches(script)) {
    states[match.group(1) ?? ''] = match.group(2) ?? '';
  }

  final rows = <List<Object?>>[];
  final seen = <String>{};
  for (final match in _vmContextRegex.allMatches(html)) {
    final name = _decodeJsString(match.group(1) ?? '');
    final uuid = match.group(2) ?? name;
    seen.add(uuid);
    final state = states[uuid] ?? '';
    rows.add(<Object?>[
      uuid,
      name,
      _vmStatus(state),
      '虚拟机',
      ManagementItemType.vm.index,
      uuid,
      const <String>[],
    ]);
  }

  for (final entry in states.entries) {
    if (seen.contains(entry.key)) {
      continue;
    }
    rows.add(<Object?>[
      entry.key,
      entry.key,
      _vmStatus(entry.value),
      '虚拟机',
      ManagementItemType.vm.index,
      entry.key,
      const <String>[],
    ]);
  }
  return rows;
}

List<UnraidManagementItem> _managementItemsFromRows(List<List<Object?>> rows) {
  final types = ManagementItemType.values;
  return [
    for (final row in rows)
      UnraidManagementItem(
        id: row[0] as String,
        title: row[1] as String,
        status: row[2] as String,
        description: row[3] as String,
        type: types[row[4] as int],
        detail: row[5] as String,
        tags: (row[6] as List<dynamic>).cast<String>(),
      ),
  ];
}

