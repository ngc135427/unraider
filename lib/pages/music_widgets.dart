part of 'music_page.dart';

class _MusicScaffold extends StatelessWidget {
  const _MusicScaffold({
    required this.title,
    this.child,
    this.body,
    this.onRefresh,
  }) : assert(child != null || body != null);

  final String title;
  /// Scrollable content for short pages (library summary, etc.).
  final Widget? child;
  /// Full-height body for virtualized lists (avoids nested unbounded scroll).
  final Widget? body;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    Widget content = body ??
        SingleChildScrollView(
          physics: onRefresh == null
              ? null
              : const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(30, 12, 30, 30),
          child: FadeSlide(
            // Library summary rebuilds on search; skip re-entrance animation.
            animate: false,
            child: child!,
          ),
        );
    if (onRefresh != null && body == null) {
      content = RefreshIndicator(
        onRefresh: () async => onRefresh!(),
        child: content,
      );
    }

    return PhoneFrame(
      maxContentWidth: 900,
      child: Column(
        children: [
          SizedBox(
            height: 48,
            child: Stack(
              children: [
                Positioned(
                  left: 8,
                  top: 0,
                  bottom: 0,
                  child: TextButton.icon(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    label: const Text(
                      '返回',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ),
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 112),
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                if (onRefresh != null)
                  Positioned(
                    right: 8,
                    top: 0,
                    bottom: 0,
                    child: IconButton(
                      tooltip: '刷新',
                      onPressed: onRefresh,
                      icon: const Icon(Icons.refresh, color: Colors.white),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
              ),
              child: content,
            ),
          ),
        ],
      ),
    );
  }
}

class _MusicSummary extends StatelessWidget {
  const _MusicSummary({
    required this.songCount,
    required this.albumCount,
    required this.losslessCount,
    required this.onSongsTap,
  });

  final int songCount;
  final int albumCount;
  final int losslessCount;
  final VoidCallback onSongsTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppTheme.background,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primary.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          _MusicStat(
            label: '歌曲',
            value: '$songCount',
            onTap: onSongsTap,
          ),
          _MusicStat(label: '专辑', value: '$albumCount'),
          _MusicStat(label: '无损', value: '$losslessCount'),
        ],
      ),
    );
  }
}

class _MusicStat extends StatelessWidget {
  const _MusicStat({required this.label, required this.value, this.onTap});

  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              children: [
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.primary,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(color: AppTheme.textLight, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TrackSearchBox extends StatelessWidget {
  const _TrackSearchBox({this.onChanged});

  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: AppTheme.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.softLine),
      ),
      child: Row(
        children: [
          const Icon(Icons.search, color: AppTheme.primary, size: 20),
          const SizedBox(width: 9),
          Expanded(
            child: TextField(
              onChanged: onChanged,
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: '搜索歌曲、专辑',
                hintStyle: TextStyle(color: AppTheme.textLight, fontSize: 14),
              ),
              style: const TextStyle(color: AppTheme.textDark, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayerProgress extends StatelessWidget {
  const _PlayerProgress({required this.player});

  final AudioPlayer player;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration?>(
      stream: player.durationStream,
      builder: (context, durationSnapshot) {
        final duration = durationSnapshot.data ?? Duration.zero;
        return StreamBuilder<Duration>(
          stream: player.positionStream,
          builder: (context, positionSnapshot) {
            final position = positionSnapshot.data ?? Duration.zero;
            final totalMs = duration.inMilliseconds;
            final value = totalMs <= 0
                ? 0.0
                : (position.inMilliseconds / totalMs).clamp(0.0, 1.0);
            return Column(
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 7,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 14,
                    ),
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white.withValues(alpha: 0.22),
                    thumbColor: Colors.white,
                    overlayColor: Colors.white24,
                  ),
                  child: Slider(
                    value: value,
                    onChanged: totalMs <= 0
                        ? null
                        : (next) {
                            final seekTo = Duration(
                              milliseconds: (next * totalMs).round(),
                            );
                            unawaited(player.seek(seekTo));
                          },
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _formatPlayerTime(position),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.76),
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      totalMs <= 0 ? '--:--' : _formatPlayerTime(duration),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.76),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _PlayerControls extends StatelessWidget {
  const _PlayerControls({
    required this.player,
    required this.enabled,
    required this.canSkip,
    required this.onPlayPause,
    required this.shuffle,
    required this.repeatMode,
    required this.onToggleShuffle,
    required this.onCycleRepeat,
    this.onPrevious,
    this.onNext,
    this.onRetry,
  });

  final AudioPlayer player;
  final bool enabled;
  final bool canSkip;
  final bool shuffle;
  final MusicRepeatMode repeatMode;
  final VoidCallback onPlayPause;
  final VoidCallback onToggleShuffle;
  final VoidCallback onCycleRepeat;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final (repeatIcon, repeatLabel, repeatActive) = switch (repeatMode) {
      MusicRepeatMode.off => (Icons.repeat, '顺序播放', false),
      MusicRepeatMode.all => (Icons.repeat, '列表循环', true),
      MusicRepeatMode.one => (Icons.repeat_one, '单曲循环', true),
    };

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              tooltip: shuffle ? '关闭随机' : '随机播放',
              onPressed: onToggleShuffle,
              icon: Icon(
                Icons.shuffle,
                color: Colors.white.withValues(alpha: shuffle ? 1 : 0.45),
                size: 26,
              ),
            ),
            IconButton(
              tooltip: '上一首',
              onPressed: canSkip ? onPrevious : null,
              icon: Icon(
                Icons.skip_previous,
                color: Colors.white.withValues(alpha: canSkip ? 1 : 0.35),
                size: 34,
              ),
            ),
            const SizedBox(width: 10),
            StreamBuilder<PlayerState>(
              stream: player.playerStateStream,
              builder: (context, snapshot) {
                final playing = snapshot.data?.playing ?? false;
                final processing = snapshot.data?.processingState;
                final busy = processing == ProcessingState.loading ||
                    processing == ProcessingState.buffering;
                return Material(
                  color: Colors.white,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: enabled ? onPlayPause : null,
                    child: SizedBox(
                      width: 64,
                      height: 64,
                      child: busy
                          ? const Padding(
                              padding: EdgeInsets.all(18),
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              playing ? Icons.pause : Icons.play_arrow,
                              color: enabled
                                  ? AppTheme.primary
                                  : AppTheme.textLight,
                              size: 34,
                            ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(width: 10),
            IconButton(
              tooltip: '下一首',
              onPressed: canSkip ? onNext : null,
              icon: Icon(
                Icons.skip_next,
                color: Colors.white.withValues(alpha: canSkip ? 1 : 0.35),
                size: 34,
              ),
            ),
            IconButton(
              tooltip: repeatLabel,
              onPressed: onCycleRepeat,
              icon: Icon(
                repeatIcon,
                color: Colors.white.withValues(alpha: repeatActive ? 1 : 0.45),
                size: 26,
              ),
            ),
          ],
        ),
        if (onRetry != null) ...[
          const SizedBox(height: 10),
          TextButton(
            onPressed: onRetry,
            child: const Text(
              '重试',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ],
    );
  }
}

String _formatPlayerTime(Duration value) {
  final total = value.inSeconds;
  final minutes = total ~/ 60;
  final seconds = (total % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

class _NowPlayingCard extends StatelessWidget {
  const _NowPlayingCard({
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.enabled = true,
  });

  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(12),
        child: Ink(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: enabled
                  ? const [Color(0xFF3498DB), Color(0xFF52C41A)]
                  : const [Color(0xFF90A4AE), Color(0xFF78909C)],
            ),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF3498DB).withValues(alpha: 0.25),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              const Icon(Icons.play_circle_fill, color: Colors.white, size: 42),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '正在播放',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.open_in_full, color: Colors.white),
            ],
          ),
        ),
      ),
    );
  }
}

class _TrackTile extends StatelessWidget {
  const _TrackTile({
    required this.track,
    required this.album,
    required this.onTap,
    this.selected = false,
  });

  final UnraidFileEntry track;
  final String album;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final icon = track.isLossless ? Icons.high_quality : Icons.music_note;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: selected
            ? AppTheme.primary.withValues(alpha: 0.08)
            : AppTheme.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: selected ? AppTheme.primary.withValues(alpha: 0.35) : AppTheme.softLine,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: AppTheme.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _displayTitle(track.name),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.textDark,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        album,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.textMedium,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  track.size.isEmpty ? '' : track.size,
                  style: const TextStyle(color: AppTheme.textLight, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MusicLoading extends StatelessWidget {
  const _MusicLoading({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(label, style: const TextStyle(color: AppTheme.textMedium)),
        ],
      ),
    );
  }
}

class _MusicState extends StatelessWidget {
  const _MusicState({
    required this.icon,
    required this.title,
    required this.detail,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String detail;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 36),
      child: Column(
        children: [
          Icon(icon, size: 42, color: AppTheme.primary),
          const SizedBox(height: 14),
          Text(
            title,
            style: const TextStyle(
              color: AppTheme.textDark,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.textMedium),
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
    );
  }
}

