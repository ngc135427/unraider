part of 'unraid_client.dart';

enum ManagementItemType { docker, vm, share }

enum ManagementAction { start, stop, restart }

class UnraidDashboard {
  const UnraidDashboard({
    required this.serverName,
    required this.serverDescription,
    required this.guid,
    required this.ownerName,
    required this.registration,
    required this.model,
    required this.version,
    required this.status,
    required this.lanIp,
    required this.wanIp,
    required this.localUrl,
    required this.remoteUrl,
    required this.uptime,
    required this.cpuSummary,
    required this.cpuPercent,
    required this.baseboardSummary,
    required this.osSummary,
    required this.packagesSummary,
    required this.memoryUsage,
    required this.memoryPercent,
    required this.arrayState,
    required this.arrayUsage,
    required this.arrayPercent,
    required this.paritySummary,
    required this.notificationInfo,
    required this.notificationWarning,
    required this.notificationAlert,
    required this.notificationTotal,
    required this.notifications,
    required this.diskItems,
    required this.networkItems,
    required this.upsItems,
    required this.pluginItems,
    required this.securityItems,
    required this.cloudItems,
    required this.logItems,
    required this.servicesSummary,
    required this.dockerNetworkSummary,
    required this.dockerConflictSummary,
    required this.dockerItems,
    required this.vmItems,
    required this.shareItems,
  });

  final String serverName;
  final String serverDescription;
  final String guid;
  final String ownerName;
  final String registration;
  final String model;
  final String version;
  final String status;
  final String lanIp;
  final String wanIp;
  final String localUrl;
  final String remoteUrl;
  final String uptime;
  final String cpuSummary;
  final double cpuPercent;
  final String baseboardSummary;
  final String osSummary;
  final String packagesSummary;
  final String memoryUsage;
  final double memoryPercent;
  final String arrayState;
  final String arrayUsage;
  final double arrayPercent;
  final String paritySummary;
  final int notificationInfo;
  final int notificationWarning;
  final int notificationAlert;
  final int notificationTotal;
  final List<UnraidNotification> notifications;
  final List<UnraidInfoItem> diskItems;
  final List<UnraidInfoItem> networkItems;
  final List<UnraidInfoItem> upsItems;
  final List<UnraidInfoItem> pluginItems;
  final List<UnraidInfoItem> securityItems;
  final List<UnraidInfoItem> cloudItems;
  final List<UnraidInfoItem> logItems;
  final String servicesSummary;
  final String dockerNetworkSummary;
  final String dockerConflictSummary;
  final List<UnraidManagementItem> dockerItems;
  final List<UnraidManagementItem> vmItems;
  final List<UnraidManagementItem> shareItems;

  UnraidDashboard copyWith({
    String? serverName,
    String? serverDescription,
    String? guid,
    String? ownerName,
    String? registration,
    String? model,
    String? version,
    String? status,
    String? lanIp,
    String? wanIp,
    String? localUrl,
    String? remoteUrl,
    String? uptime,
    String? cpuSummary,
    double? cpuPercent,
    String? baseboardSummary,
    String? osSummary,
    String? packagesSummary,
    String? memoryUsage,
    double? memoryPercent,
    String? arrayState,
    String? arrayUsage,
    double? arrayPercent,
    String? paritySummary,
    int? notificationInfo,
    int? notificationWarning,
    int? notificationAlert,
    int? notificationTotal,
    List<UnraidNotification>? notifications,
    List<UnraidInfoItem>? diskItems,
    List<UnraidInfoItem>? networkItems,
    List<UnraidInfoItem>? upsItems,
    List<UnraidInfoItem>? pluginItems,
    List<UnraidInfoItem>? securityItems,
    List<UnraidInfoItem>? cloudItems,
    List<UnraidInfoItem>? logItems,
    String? servicesSummary,
    String? dockerNetworkSummary,
    String? dockerConflictSummary,
    List<UnraidManagementItem>? dockerItems,
    List<UnraidManagementItem>? vmItems,
    List<UnraidManagementItem>? shareItems,
  }) {
    return UnraidDashboard(
      serverName: serverName ?? this.serverName,
      serverDescription: serverDescription ?? this.serverDescription,
      guid: guid ?? this.guid,
      ownerName: ownerName ?? this.ownerName,
      registration: registration ?? this.registration,
      model: model ?? this.model,
      version: version ?? this.version,
      status: status ?? this.status,
      lanIp: lanIp ?? this.lanIp,
      wanIp: wanIp ?? this.wanIp,
      localUrl: localUrl ?? this.localUrl,
      remoteUrl: remoteUrl ?? this.remoteUrl,
      uptime: uptime ?? this.uptime,
      cpuSummary: cpuSummary ?? this.cpuSummary,
      cpuPercent: cpuPercent ?? this.cpuPercent,
      baseboardSummary: baseboardSummary ?? this.baseboardSummary,
      osSummary: osSummary ?? this.osSummary,
      packagesSummary: packagesSummary ?? this.packagesSummary,
      memoryUsage: memoryUsage ?? this.memoryUsage,
      memoryPercent: memoryPercent ?? this.memoryPercent,
      arrayState: arrayState ?? this.arrayState,
      arrayUsage: arrayUsage ?? this.arrayUsage,
      arrayPercent: arrayPercent ?? this.arrayPercent,
      paritySummary: paritySummary ?? this.paritySummary,
      notificationInfo: notificationInfo ?? this.notificationInfo,
      notificationWarning: notificationWarning ?? this.notificationWarning,
      notificationAlert: notificationAlert ?? this.notificationAlert,
      notificationTotal: notificationTotal ?? this.notificationTotal,
      notifications: notifications ?? this.notifications,
      diskItems: diskItems ?? this.diskItems,
      networkItems: networkItems ?? this.networkItems,
      upsItems: upsItems ?? this.upsItems,
      pluginItems: pluginItems ?? this.pluginItems,
      securityItems: securityItems ?? this.securityItems,
      cloudItems: cloudItems ?? this.cloudItems,
      logItems: logItems ?? this.logItems,
      servicesSummary: servicesSummary ?? this.servicesSummary,
      dockerNetworkSummary: dockerNetworkSummary ?? this.dockerNetworkSummary,
      dockerConflictSummary:
          dockerConflictSummary ?? this.dockerConflictSummary,
      dockerItems: dockerItems ?? this.dockerItems,
      vmItems: vmItems ?? this.vmItems,
      shareItems: shareItems ?? this.shareItems,
    );
  }
}

class UnraidManagementItem {
  const UnraidManagementItem({
    required this.id,
    required this.title,
    required this.status,
    required this.description,
    required this.type,
    this.detail = '',
    this.progress = 0,
    this.tags = const <String>[],
    this.details = const <UnraidInfoItem>[],
  });

  final String id;
  final String title;
  final String status;
  final String description;
  final String detail;
  final double progress;
  final List<String> tags;
  final List<UnraidInfoItem> details;
  final ManagementItemType type;
}

enum InfoSeverity { normal, success, warning, danger }

class UnraidInfoItem {
  const UnraidInfoItem({
    required this.title,
    required this.value,
    this.description = '',
    this.severity = InfoSeverity.normal,
  });

  final String title;
  final String value;
  final String description;
  final InfoSeverity severity;
}

class UnraidNotification {
  const UnraidNotification({
    required this.title,
    required this.description,
    required this.severity,
    this.subject = '',
    this.timestamp = '',
  });

  final String title;
  final String subject;
  final String description;
  final InfoSeverity severity;
  final String timestamp;
}

class UnraidFileEntry {
  factory UnraidFileEntry({
    required String name,
    required String path,
    required bool isDirectory,
    required int sizeBytes,
    required String size,
    required String modified,
    required DateTime? modifiedDate,
    int durationMs = 0,
    String? thumbnailPath,
  }) {
    final nameLower = name.toLowerCase();
    return UnraidFileEntry._(
      name: name,
      nameLower: nameLower,
      path: path,
      isDirectory: isDirectory,
      sizeBytes: sizeBytes,
      size: size,
      modified: modified,
      modifiedDate: modifiedDate,
      durationMs: durationMs,
      thumbnailPath: thumbnailPath,
      isImage:
          !isDirectory && _nameHasExtensionLower(nameLower, _imageExtensions),
      isVideo:
          !isDirectory && _nameHasExtensionLower(nameLower, _videoExtensions),
      isAudio:
          !isDirectory && _nameHasExtensionLower(nameLower, _audioExtensions),
      isLossless: !isDirectory &&
          _nameHasExtensionLower(nameLower, _losslessAudioExtensions),
    );
  }

  const UnraidFileEntry._({
    required this.name,
    required this.nameLower,
    required this.path,
    required this.isDirectory,
    required this.sizeBytes,
    required this.size,
    required this.modified,
    required this.modifiedDate,
    required this.durationMs,
    required this.thumbnailPath,
    required this.isImage,
    required this.isVideo,
    required this.isAudio,
    required this.isLossless,
  });

  final String name;

  /// Cached lowercase name for search haystacks and extension checks.
  final String nameLower;
  final String path;
  final bool isDirectory;
  final int sizeBytes;
  final String size;
  final String modified;
  final DateTime? modifiedDate;
  final int durationMs;
  final String? thumbnailPath;

  /// Media kind flags are computed once at construction so list filters,
  /// share browsers, and album tiles do not re-lower/scan extensions.
  final bool isImage;
  final bool isVideo;
  final bool isAudio;

  /// True for flac/wav/aiff/alac/ape — used by music library stats/tiles.
  final bool isLossless;

  bool get isMedia => isImage || isVideo || isAudio;
}

bool _nameHasExtensionLower(String nameLower, List<String> extensions) {
  for (final extension in extensions) {
    if (nameLower.endsWith(extension)) {
      return true;
    }
  }
  return false;
}

const _imageExtensions = <String>[
  '.jpg',
  '.jpeg',
  '.png',
  '.gif',
  '.webp',
  '.bmp',
  '.heic',
];

const _videoExtensions = <String>[
  '.mp4',
  '.mov',
  '.m4v',
  '.mkv',
  '.avi',
  '.webm',
];

const _audioExtensions = <String>[
  '.mp3',
  '.flac',
  '.wav',
  '.aac',
  '.m4a',
  '.ogg',
  '.opus',
  '.wma',
  '.aiff',
  '.ape',
  '.alac',
];

const _losslessAudioExtensions = <String>[
  '.flac',
  '.wav',
  '.aiff',
  '.alac',
  '.ape',
];
