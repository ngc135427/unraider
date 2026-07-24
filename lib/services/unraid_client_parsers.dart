part of 'unraid_client.dart';

List<UnraidManagementItem> _parseDockerItems(String body) {
  final items = <UnraidManagementItem>[];
  final script =
      body.split('\u0000').length > 1 ? body.split('\u0000')[1] : body;
  final regex = RegExp(
    r'''docker\.push\(\{name:'((?:\\'|[^'])*)',id:'([^']*)',state:(\d+),pause:(\d+),update:(\d+)''',
  );

  for (final match in regex.allMatches(script)) {
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
    items.add(
      UnraidManagementItem(
        id: id,
        title: name,
        status: status,
        description: 'Docker 容器',
        type: ManagementItemType.docker,
        detail: id,
        tags: <String>[
          if (hasUpdate) '有更新',
        ],
      ),
    );
  }
  return items;
}

List<UnraidManagementItem> _parseVmItems(String body) {
  final parts = body.split('\u0000');
  final html = parts.isNotEmpty ? parts.first : body;
  final script = parts.length > 1 ? parts.last : body;
  final states = <String, String>{};
  final stateRegex =
      RegExp(r'''kvm\.push\(\{id:'([^']*)',state:'([^']*)'\}\);''');
  for (final match in stateRegex.allMatches(script)) {
    states[match.group(1) ?? ''] = match.group(2) ?? '';
  }

  final items = <UnraidManagementItem>[];
  final nameRegex = RegExp(r"addVMContext\('((?:\\'|[^'])*)','([^']*)'");
  for (final match in nameRegex.allMatches(html)) {
    final name = _decodeJsString(match.group(1) ?? '');
    final uuid = match.group(2) ?? name;
    final state = states[uuid] ?? '';
    items.add(
      UnraidManagementItem(
        id: uuid,
        title: name,
        status: _vmStatus(state),
        description: '虚拟机',
        type: ManagementItemType.vm,
        detail: uuid,
      ),
    );
  }

  for (final entry in states.entries) {
    if (items.any((item) => item.id == entry.key)) {
      continue;
    }
    items.add(
      UnraidManagementItem(
        id: entry.key,
        title: entry.key,
        status: _vmStatus(entry.value),
        description: '虚拟机',
        type: ManagementItemType.vm,
        detail: entry.key,
      ),
    );
  }
  return items;
}

