part of 'main_shell_page.dart';

class _DetailPanel extends StatelessWidget {
  const _DetailPanel({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.softLine),
      ),
      child: Column(children: children),
    );
  }
}

class _DetailInfoRow extends StatelessWidget {
  const _DetailInfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: AppTheme.primary, size: 20),
          const SizedBox(width: 10),
          SizedBox(
            width: 58,
            child: Text(
              label,
              style: const TextStyle(color: AppTheme.textLight, fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.textDark,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ManagementActionButton extends StatelessWidget {
  const _ManagementActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 42,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 20),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          side: const BorderSide(color: AppTheme.line),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }
}

class _FileEntryTile extends StatelessWidget {
  const _FileEntryTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.onLongPress,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.background,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.softLine),
          ),
          child: Row(
            children: [
              Icon(icon, color: AppTheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.textDark,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.textLight,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Icon(
                icon == Icons.image ? Icons.visibility : Icons.chevron_right,
                color: AppTheme.textLight,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ImagePreview extends StatefulWidget {
  const _ImagePreview({
    required this.client,
    required this.entries,
    required this.initialIndex,
  });

  final UnraidClient client;
  final List<UnraidFileEntry> entries;
  final int initialIndex;

  @override
  State<_ImagePreview> createState() => _ImagePreviewState();
}

class _ImagePreviewState extends State<_ImagePreview> {
  late final PageController _controller;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex < 0 ? 0 : widget.initialIndex;
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _go(int delta) {
    final next = (_index + delta).clamp(0, widget.entries.length - 1);
    if (next == _index) {
      return;
    }
    _controller.animateToPage(
      next,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entries[_index];
    return ColoredBox(
      color: Colors.black,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 52,
              child: Row(
                children: [
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      widget.entries.length > 1
                          ? '${entry.name}  ${_index + 1}/${widget.entries.length}'
                          : entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '上一张',
                    onPressed: _index == 0 ? null : () => _go(-1),
                    icon: const Icon(Icons.chevron_left, color: Colors.white),
                  ),
                  IconButton(
                    tooltip: '下一张',
                    onPressed: _index == widget.entries.length - 1
                        ? null
                        : () => _go(1),
                    icon: const Icon(Icons.chevron_right, color: Colors.white),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: widget.entries.length,
                // Keep only the current page + neighbors warm so swiping a
                // large album does not start dozens of full-file downloads.
                allowImplicitScrolling: false,
                onPageChanged: (value) => setState(() => _index = value),
                itemBuilder: (context, index) {
                  final distance = (index - _index).abs();
                  return _ImagePreviewPage(
                    key: ValueKey<String>(widget.entries[index].path),
                    client: widget.client,
                    entry: widget.entries[index],
                    active: distance <= 1,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImagePreviewPage extends StatefulWidget {
  const _ImagePreviewPage({
    super.key,
    required this.client,
    required this.entry,
    required this.active,
  });

  final UnraidClient client;
  final UnraidFileEntry entry;
  final bool active;

  @override
  State<_ImagePreviewPage> createState() => _ImagePreviewPageState();
}

class _ImagePreviewPageState extends State<_ImagePreviewPage> {
  Future<File>? _fileFuture;
  double _progress = 0;
  bool _decodeSuccessLogged = false;

  @override
  void initState() {
    super.initState();
    if (widget.active) {
      _fileFuture = _loadPreviewFile();
    }
  }

  @override
  void didUpdateWidget(covariant _ImagePreviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active &&
        _fileFuture == null &&
        oldWidget.entry.path == widget.entry.path) {
      setState(() {
        _fileFuture = _loadPreviewFile();
      });
    }
  }

  Future<File> _loadPreviewFile() {
    final path = widget.entry.path;
    final cached = _sharePreviewFileCache.remove(path);
    if (cached != null) {
      _sharePreviewFileCache[path] = cached;
      return cached;
    }

    final future = () async {
      await AppLogger.log(
        'share_preview_fetch_start path=$path '
        'sizeBytes=${widget.entry.sizeBytes}',
      );
      try {
        final file = await MediaCache.ensureLocalFile(
          client: widget.client,
          remotePath: path,
          expectedSizeBytes: widget.entry.sizeBytes,
          fileName: widget.entry.name,
          onProgress: (value) {
            if (!mounted) {
              return;
            }
            setState(() => _progress = value);
          },
        );
        await AppLogger.log(
          'share_preview_fetch_success path=$path '
          'bytes=${await file.length()}',
        );
        return file;
      } on Object catch (error, stackTrace) {
        await AppLogger.log(
          'share_preview_fetch_error path=$path',
          error: error,
          stackTrace: stackTrace,
        );
        rethrow;
      }
    }();

    if (_sharePreviewFileCache.length >= _maxSharePreviewCacheEntries) {
      _sharePreviewFileCache.remove(_sharePreviewFileCache.keys.first);
    }
    _sharePreviewFileCache[path] = future;
    unawaited(
      future.then<void>(
        (_) {},
        onError: (Object _) {
          if (identical(_sharePreviewFileCache[path], future)) {
            _sharePreviewFileCache.remove(path);
          }
        },
      ),
    );
    return future;
  }

  @override
  Widget build(BuildContext context) {
    final fileFuture = _fileFuture;
    if (fileFuture == null) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(
          child: Icon(Icons.image_outlined, color: Colors.white24, size: 48),
        ),
      );
    }

    return FutureBuilder<File>(
      future: fileFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          final pct = (_progress * 100).clamp(0, 100).toStringAsFixed(0);
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(
                  value: _progress > 0 && _progress < 1 ? _progress : null,
                ),
                const SizedBox(height: 14),
                Text(
                  '正在流式加载… $pct%'
                  '${widget.entry.size.isEmpty ? '' : ' · ${widget.entry.size}'}',
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          );
        }

        if (snapshot.hasError || !snapshot.hasData) {
          return _PreviewMessage(
            message: snapshot.error?.toString() ?? '图片加载失败',
            color: AppTheme.danger,
          );
        }

        final file = snapshot.data!;
        return InteractiveViewer(
          minScale: 0.5,
          maxScale: 4,
          child: Center(
            child: Image.file(
              file,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              cacheWidth: _maxImagePreviewDecodeExtent,
              cacheHeight: _maxImagePreviewDecodeExtent,
              frameBuilder: (context, child, frame, _) {
                if (frame != null && !_decodeSuccessLogged) {
                  _decodeSuccessLogged = true;
                  unawaited(
                    AppLogger.log(
                      'share_preview_decode_success '
                      'path=${widget.entry.path}',
                    ),
                  );
                }
                return child;
              },
              errorBuilder: (_, error, stackTrace) {
                unawaited(
                  AppLogger.log(
                    'share_preview_decode_error '
                    'path=${widget.entry.path}',
                    error: error,
                    stackTrace: stackTrace,
                  ),
                );
                return const _PreviewMessage(
                  message: '图片格式不支持或文件已损坏',
                  color: AppTheme.danger,
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _PreviewMessage extends StatelessWidget {
  const _PreviewMessage({
    required this.message,
    required this.color,
  });

  final String message;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: color,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}

class _TextPreview extends StatefulWidget {
  const _TextPreview({
    required this.client,
    required this.entry,
  });

  final UnraidClient client;
  final UnraidFileEntry entry;

  @override
  State<_TextPreview> createState() => _TextPreviewState();
}

class _TextPreviewState extends State<_TextPreview> {
  late final bool _isTooLarge;
  late final Future<String>? _textFuture;

  @override
  void initState() {
    super.initState();
    _isTooLarge = widget.entry.sizeBytes > _maxTextPreviewBytes;
    _textFuture = _isTooLarge ? null : _loadText();
  }

  Future<String> _loadText() {
    final path = widget.entry.path;
    final cached = _sharePreviewTextCache.remove(path);
    if (cached != null) {
      // LRU touch for recently opened text previews.
      _sharePreviewTextCache[path] = cached;
      return cached;
    }

    final future = () async {
      final bytes = await widget.client.fetchFileBytes(path);
      // Large text payloads decode off the UI isolate to avoid jank.
      if (bytes.length >= 32 * 1024) {
        return Isolate.run(
          () => utf8.decode(bytes, allowMalformed: true),
        );
      }
      return utf8.decode(bytes, allowMalformed: true);
    }();

    if (_sharePreviewTextCache.length >= _maxSharePreviewTextCacheEntries) {
      _sharePreviewTextCache.remove(_sharePreviewTextCache.keys.first);
    }
    _sharePreviewTextCache[path] = future;
    unawaited(
      future.then<void>(
        (_) {},
        onError: (Object _) {
          if (identical(_sharePreviewTextCache[path], future)) {
            _sharePreviewTextCache.remove(path);
          }
        },
      ),
    );
    return future;
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 860, maxHeight: 720),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textDark,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Flexible(
            child: _isTooLarge
                ? _PreviewMessage(
                    message: '文本超过 1 MB，暂不直接预览（${widget.entry.size}）',
                    color: AppTheme.danger,
                  )
                : FutureBuilder<String>(
                    future: _textFuture,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState != ConnectionState.done) {
                        return const Padding(
                          padding: EdgeInsets.all(48),
                          child: CircularProgressIndicator(),
                        );
                      }
                      if (snapshot.hasError || !snapshot.hasData) {
                        return _PreviewMessage(
                          message: snapshot.error?.toString() ?? '文本加载失败',
                          color: AppTheme.danger,
                        );
                      }
                      return Scrollbar(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(16),
                          child: SelectableText(
                            snapshot.data!,
                            style: const TextStyle(
                              color: AppTheme.textDark,
                              fontSize: 13,
                              height: 1.45,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ShareVideoPreview extends StatefulWidget {
  const _ShareVideoPreview({
    required this.client,
    required this.entries,
    required this.initialIndex,
  });

  final UnraidClient client;
  final List<UnraidFileEntry> entries;
  final int initialIndex;

  @override
  State<_ShareVideoPreview> createState() => _ShareVideoPreviewState();
}

class _ShareVideoPreviewState extends State<_ShareVideoPreview> {
  late final PageController _controller;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex < 0 ? 0 : widget.initialIndex;
    _index = _index.clamp(0, widget.entries.length - 1);
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _go(int delta) {
    final next = (_index + delta).clamp(0, widget.entries.length - 1);
    if (next == _index) {
      return;
    }
    _controller.animateToPage(
      next,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entries[_index];
    return ColoredBox(
      color: Colors.black,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 52,
              child: Row(
                children: [
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      widget.entries.length > 1
                          ? '${entry.name}  ${_index + 1}/${widget.entries.length}'
                          : entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '上一个视频',
                    onPressed: _index == 0 ? null : () => _go(-1),
                    icon: const Icon(Icons.chevron_left, color: Colors.white),
                  ),
                  IconButton(
                    tooltip: '下一个视频',
                    onPressed: _index == widget.entries.length - 1
                        ? null
                        : () => _go(1),
                    icon: const Icon(Icons.chevron_right, color: Colors.white),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: widget.entries.length,
                allowImplicitScrolling: false,
                onPageChanged: (value) => setState(() => _index = value),
                itemBuilder: (context, index) {
                  final item = widget.entries[index];
                  return _ShareVideoPreviewPage(
                    key: ValueKey<String>(item.path),
                    client: widget.client,
                    entry: item,
                    active: index == _index,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShareVideoPreviewPage extends StatefulWidget {
  const _ShareVideoPreviewPage({
    super.key,
    required this.client,
    required this.entry,
    required this.active,
  });

  final UnraidClient client;
  final UnraidFileEntry entry;
  final bool active;

  @override
  State<_ShareVideoPreviewPage> createState() => _ShareVideoPreviewPageState();
}

class _ShareVideoPreviewPageState extends State<_ShareVideoPreviewPage> {
  VideoPlayerController? _controller;
  Future<void>? _initFuture;
  StreamSubscription<double>? _progressSubscription;
  String? _error;
  bool _started = false;
  bool _usingFallback = false;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    if (widget.active) {
      unawaited(_start());
    }
  }

  @override
  void didUpdateWidget(covariant _ShareVideoPreviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active) {
      if (!_started) {
        unawaited(_start());
      } else if (_controller != null) {
        unawaited(_controller!.play());
      }
    } else if (!widget.active && _controller != null) {
      unawaited(_controller!.pause());
    }
  }

  Future<void> _start() async {
    if (_started) {
      return;
    }
    _started = true;
    final future = _loadAndPlay();
    setState(() {
      _initFuture = future;
      _error = null;
    });
    try {
      await future;
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.toString();
      });
    }
  }

  Future<void> _loadAndPlay() async {
    final directController = await RemoteVideoStream.tryOpen(
      client: widget.client,
      entry: widget.entry,
    );
    if (directController != null) {
      await directController.setLooping(true);
      if (widget.active) {
        await directController.play();
      }
      if (!mounted) {
        await directController.dispose();
        return;
      }
      setState(() {
        _controller = directController;
        _error = null;
      });
      return;
    }
    if (mounted) {
      setState(() => _usingFallback = true);
    }
    final handle = await MediaCache.ensureProgressive(
      client: widget.client,
      remotePath: widget.entry.path,
      expectedSizeBytes: widget.entry.sizeBytes,
      fileName: widget.entry.name,
    );
    _progressSubscription = handle.progress.listen((value) {
      if (!mounted) {
        return;
      }
      setState(() => _progress = value);
    });
    await handle.ready;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    final controller = VideoPlayerController.file(handle.file);
    await controller.initialize();
    await controller.setLooping(true);
    if (widget.active) {
      await controller.play();
    }
    if (!mounted) {
      await controller.dispose();
      return;
    }
    setState(() {
      _controller = controller;
      _error = null;
    });
  }

  @override
  void dispose() {
    unawaited(_progressSubscription?.cancel() ?? Future<void>.value());
    final controller = _controller;
    _controller = null;
    unawaited(controller?.dispose() ?? Future<void>.value());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _PreviewMessage(message: _error!, color: AppTheme.danger);
    }
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 14),
            Text(
              widget.active
                  ? _usingFallback
                      ? 'WebDAV 不可用，正在流式缓冲… ${(_progress * 100).clamp(0, 100).toStringAsFixed(0)}%'
                      : '正在连接 WebDAV 视频流…'
                  : '等待播放',
              style: const TextStyle(color: Colors.white70),
            ),
            if (_initFuture != null)
              FutureBuilder<void>(
                future: _initFuture,
                builder: (_, __) => const SizedBox.shrink(),
              ),
            if (widget.entry.size.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                widget.entry.size,
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
          ],
        ),
      );
    }
    return _ShareVideoPlayer(controller: controller);
  }
}

class _ShareVideoPlayer extends StatelessWidget {
  const _ShareVideoPlayer({required this.controller});

  final VideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Center(
          child: AspectRatio(
            aspectRatio: controller.value.aspectRatio == 0
                ? 16 / 9
                : controller.value.aspectRatio,
            child: VideoWakeLock(
              controller: controller,
              child: VideoPlayer(controller),
            ),
          ),
        ),
        Positioned.fill(
          child: ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              return Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () {
                    if (value.isPlaying) {
                      unawaited(controller.pause());
                    } else {
                      unawaited(controller.play());
                    }
                  },
                  child: Center(
                    child: AnimatedOpacity(
                      opacity: value.isPlaying ? 0 : 1,
                      duration: const Duration(milliseconds: 160),
                      child: Icon(
                        value.isPlaying
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_filled,
                        color: Colors.white.withValues(alpha: 0.82),
                        size: 66,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: ColoredBox(
            color: Colors.black.withValues(alpha: 0.52),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                VideoProgressIndicator(
                  controller,
                  allowScrubbing: true,
                  colors: const VideoProgressColors(
                    playedColor: Colors.white,
                    bufferedColor: Colors.white38,
                    backgroundColor: Colors.white24,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 16, 10),
                  child: ValueListenableBuilder<VideoPlayerValue>(
                    valueListenable: controller,
                    builder: (context, value, _) {
                      return VideoPlaybackControls(
                        controller: controller,
                        value: value,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

const _textPreviewExtensions = <String>{
  '.txt',
  '.log',
  '.md',
  '.json',
  '.xml',
  '.yaml',
  '.yml',
  '.csv',
  '.ini',
  '.conf',
  '.cfg',
  '.sh',
  '.dart',
};

bool _isTextPreviewEntry(UnraidFileEntry entry) {
  final dot = entry.nameLower.lastIndexOf('.');
  if (dot < 0 || dot == entry.nameLower.length - 1) {
    return false;
  }
  return _textPreviewExtensions.contains(entry.nameLower.substring(dot));
}

bool _isPdfPreviewEntry(UnraidFileEntry entry) {
  if (entry.isDirectory) {
    return false;
  }
  return entry.nameLower.endsWith('.pdf');
}

/// Fullscreen PDF preview powered by offline PDF.js inside a WebView.
class _SharePdfPreview extends StatefulWidget {
  const _SharePdfPreview({
    required this.client,
    required this.entry,
  });

  final UnraidClient client;
  final UnraidFileEntry entry;

  @override
  State<_SharePdfPreview> createState() => _SharePdfPreviewState();
}

class _SharePdfPreviewState extends State<_SharePdfPreview> {
  WebViewController? _webController;
  double _progress = 0;
  String? _error;
  bool _loadingFile = true;
  bool _viewerReady = false;
  String? _status;
  Directory? _sessionDir;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    final dir = _sessionDir;
    _sessionDir = null;
    if (dir != null) {
      unawaited(
        dir.delete(recursive: true).catchError((Object _) => dir),
      );
    }
    super.dispose();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loadingFile = true;
      _error = null;
      _status = '正在从 Unraid 下载 PDF…';
      _progress = 0;
    });
    try {
      final pdfFile = await MediaCache.ensureLocalFile(
        client: widget.client,
        remotePath: widget.entry.path,
        expectedSizeBytes: widget.entry.sizeBytes,
        fileName: widget.entry.name,
        onProgress: (value) {
          if (!mounted) {
            return;
          }
          setState(() {
            _progress = value;
            final pct = (value * 100).clamp(0, 100).toStringAsFixed(0);
            _status = '正在下载 PDF… $pct%';
          });
        },
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _status = '正在准备 PDF.js 阅读器…';
        _progress = 1;
      });

      final session = await _prepareViewerSession(pdfFile);
      if (!mounted) {
        return;
      }
      _sessionDir = session.dir;

      final controller = WebViewController();
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setBackgroundColor(const Color(0xFF121212));
      // Android: allow file:// HTML to read sibling PDF/worker scripts.
      final platform = controller.platform;
      if (platform is AndroidWebViewController) {
        await platform.setAllowFileAccess(true);
        await platform.setMediaPlaybackRequiresUserGesture(false);
      }
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (url) {
            unawaited(_onViewerPageFinished(controller));
          },
          onWebResourceError: (error) {
            if (!mounted) {
              return;
            }
            setState(() {
              _error = 'WebView 错误：${error.description}';
              _loadingFile = false;
            });
          },
        ),
      );

      if (!mounted) {
        return;
      }
      setState(() {
        _webController = controller;
        _loadingFile = false;
        _viewerReady = false;
        _status = '正在打开阅读器…';
      });
      await controller.loadFile(session.viewerHtml.path);
    } on Object catch (error, stackTrace) {
      unawaited(
        AppLogger.log(
          'share_pdf_preview_error path=${widget.entry.path}',
          error: error,
          stackTrace: stackTrace,
        ),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _loadingFile = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _onViewerPageFinished(WebViewController controller) async {
    if (!mounted || _viewerReady) {
      return;
    }
    try {
      // Load the sibling document.pdf via PDF.js (same directory as viewer).
      await controller.runJavaScript(
        "window.openPdfFromUrl && window.openPdfFromUrl('document.pdf');",
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _viewerReady = true;
        _status = null;
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = '启动 PDF.js 失败：$error';
      });
    }
  }

  Future<({Directory dir, File viewerHtml})> _prepareViewerSession(
    File pdfFile,
  ) async {
    final root = await getTemporaryDirectory();
    final dir = Directory(
      '${root.path}/unraider_pdf_${DateTime.now().microsecondsSinceEpoch}',
    );
    await dir.create(recursive: true);

    // Copy offline PDF.js assets next to the document.
    const assets = <String>[
      'assets/pdfjs/viewer.html',
      'assets/pdfjs/pdf.min.js',
      'assets/pdfjs/pdf.worker.min.js',
    ];
    for (final asset in assets) {
      final data = await rootBundle.load(asset);
      final name = asset.split('/').last;
      final out = File('${dir.path}/$name');
      await out.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }

    // Place PDF beside viewer so file:// relative loads work.
    final targetPdf = File('${dir.path}/document.pdf');
    try {
      await pdfFile.copy(targetPdf.path);
    } on Object {
      // Fallback when source is on a content/fuse path that copy rejects.
      await targetPdf.writeAsBytes(await pdfFile.readAsBytes(), flush: true);
    }

    return (dir: dir, viewerHtml: File('${dir.path}/viewer.html'));
  }

  @override
  Widget build(BuildContext context) {
    final largeHint = widget.entry.sizeBytes > _maxPdfPreviewHintBytes;
    return ColoredBox(
      color: const Color(0xFF121212),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 52,
              child: Row(
                children: [
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      widget.entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (widget.entry.size.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Text(
                        widget.entry.size,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                ],
              ),
            ),
            if (largeHint && _loadingFile)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  '文件较大，首次下载可能需要较长时间',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
            Expanded(
              child: _error != null
                  ? _PreviewMessage(message: _error!, color: AppTheme.danger)
                  : _loadingFile || _webController == null
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircularProgressIndicator(
                                value: _progress > 0 && _progress < 1
                                    ? _progress
                                    : null,
                              ),
                              const SizedBox(height: 14),
                              Text(
                                _status ?? '准备中…',
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.white70),
                              ),
                            ],
                          ),
                        )
                      : Stack(
                          children: [
                            WebViewWidget(controller: _webController!),
                            if (!_viewerReady && _error == null)
                              Positioned(
                                left: 0,
                                right: 0,
                                top: 0,
                                child: LinearProgressIndicator(
                                  backgroundColor: Colors.white10,
                                  color: AppTheme.primary,
                                ),
                              ),
                          ],
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StateMessage extends StatelessWidget {
  const _StateMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: AppTheme.primary, size: 42),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppTheme.textDark,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppTheme.textMedium,
                fontSize: 14,
                height: 1.4,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _IconPickerDialog extends StatefulWidget {
  const _IconPickerDialog({required this.current});

  final ServerIconVariant current;

  @override
  State<_IconPickerDialog> createState() => _IconPickerDialogState();
}

class _IconPickerDialogState extends State<_IconPickerDialog> {
  late ServerIconVariant _selected = widget.current;

  @override
  Widget build(BuildContext context) {
    final variants = ServerIconVariant.values;
    return AlertDialog(
      title: const Text('选择服务器图标'),
      content: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final variant in variants)
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _selected = variant),
              child: Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _selected == variant
                        ? AppTheme.primary
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: ServerIconView(variant: variant, size: 72),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_selected),
          child: const Text('确认'),
        ),
      ],
    );
  }
}
