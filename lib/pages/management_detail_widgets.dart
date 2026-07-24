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
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
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
                onPageChanged: (value) => setState(() => _index = value),
                itemBuilder: (context, index) => _ImagePreviewPage(
                  client: widget.client,
                  entry: widget.entries[index],
                ),
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
    required this.client,
    required this.entry,
  });

  final UnraidClient client;
  final UnraidFileEntry entry;

  @override
  State<_ImagePreviewPage> createState() => _ImagePreviewPageState();
}

class _ImagePreviewPageState extends State<_ImagePreviewPage> {
  late final bool _isTooLarge;
  late final Future<Uint8List>? _bytesFuture;
  bool _decodeSuccessLogged = false;

  @override
  void initState() {
    super.initState();
    _isTooLarge = widget.entry.sizeBytes > _maxImagePreviewBytes;
    if (_isTooLarge) {
      _bytesFuture = null;
      unawaited(
        AppLogger.log(
          'share_preview_skip_large path=${widget.entry.path} '
          'sizeBytes=${widget.entry.sizeBytes} limit=$_maxImagePreviewBytes',
        ),
      );
    } else {
      _bytesFuture = _loadPreviewBytes();
    }
  }

  Future<Uint8List> _loadPreviewBytes() async {
    await AppLogger.log(
      'share_preview_fetch_start path=${widget.entry.path} '
      'sizeBytes=${widget.entry.sizeBytes}',
    );
    try {
      final bytes = await widget.client.fetchFileBytes(widget.entry.path);
      await AppLogger.log(
        'share_preview_fetch_success path=${widget.entry.path} '
        'bytes=${bytes.length}',
      );
      return bytes;
    } on Object catch (error, stackTrace) {
      await AppLogger.log(
        'share_preview_fetch_error path=${widget.entry.path}',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isTooLarge) {
      return _PreviewMessage(
        message: '文件超过 32 MB，暂不直接预览（${widget.entry.size}）',
        color: AppTheme.danger,
      );
    }

    return FutureBuilder<Uint8List>(
      future: _bytesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError || !snapshot.hasData) {
          return _PreviewMessage(
            message: snapshot.error?.toString() ?? '图片加载失败',
            color: AppTheme.danger,
          );
        }

        return InteractiveViewer(
          minScale: 0.5,
          maxScale: 4,
          child: Center(
            child: Image.memory(
              snapshot.data!,
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
                      'path=${widget.entry.path} '
                      'bytes=${snapshot.data!.length}',
                    ),
                  );
                }
                return child;
              },
              errorBuilder: (_, error, stackTrace) {
                unawaited(
                  AppLogger.log(
                    'share_preview_decode_error '
                    'path=${widget.entry.path} '
                    'bytes=${snapshot.data!.length}',
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

  Future<String> _loadText() async {
    final bytes = await widget.client.fetchFileBytes(widget.entry.path);
    return utf8.decode(bytes, allowMalformed: true);
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

bool _isTextPreviewFile(String name) {
  final lower = name.toLowerCase();
  return const <String>[
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
  ].any(lower.endsWith);
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
