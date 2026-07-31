import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../pages/music_page.dart';
import '../services/music_player_service.dart';

/// Persistent mini player shown above bottom navigation while a session is live.
class MiniPlayerBar extends StatelessWidget {
  const MiniPlayerBar({super.key, this.bottomOffset = 0});

  /// Extra bottom padding so the bar can sit above bottom navigation.
  final double bottomOffset;

  @override
  Widget build(BuildContext context) {
    final service = MusicPlayerService.instance;

    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        // Hide while the full-screen player is open so controls are not doubled.
        if (!service.hasSession ||
            service.current == null ||
            service.fullPlayerVisible) {
          return const SizedBox.shrink();
        }
        final track = service.current!;
        final title = MusicPlayerService.displayTitle(track.name);
        final subtitle = service.error ??
            (service.loading
                ? '正在流式缓冲…'
                : service.currentAlbum.isEmpty
                    ? service.rootPath
                    : service.currentAlbum);
        return Padding(
          padding: EdgeInsets.fromLTRB(12, 0, 12, 8 + bottomOffset),
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(14),
            color: const Color(0xFF1B2A41),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                InkWell(
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const MusicPlayerPage(),
                      ),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 4, 6),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFF3498DB), Color(0xFF52C41A)],
                            ),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            service.loading
                                ? Icons.hourglass_top
                                : Icons.music_note,
                            color: Colors.white,
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: service.error != null
                                      ? const Color(0xFFFFCDD2)
                                      : Colors.white70,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: '上一首',
                          visualDensity: VisualDensity.compact,
                          onPressed: service.canSkip
                              ? () => unawaited(service.skip(-1))
                              : null,
                          icon: Icon(
                            Icons.skip_previous_rounded,
                            color: Colors.white
                                .withValues(alpha: service.canSkip ? 1 : 0.35),
                          ),
                        ),
                        IconButton(
                          tooltip: service.playing ? '暂停' : '播放',
                          visualDensity: VisualDensity.compact,
                          onPressed: () =>
                              unawaited(service.togglePlayPause()),
                          icon: Icon(
                            service.loading
                                ? Icons.hourglass_empty
                                : service.playing
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                            color: Colors.white,
                          ),
                        ),
                        IconButton(
                          tooltip: '下一首',
                          visualDensity: VisualDensity.compact,
                          onPressed: service.canSkip
                              ? () => unawaited(service.skip(1))
                              : null,
                          icon: Icon(
                            Icons.skip_next_rounded,
                            color: Colors.white
                                .withValues(alpha: service.canSkip ? 1 : 0.35),
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭播放器',
                          visualDensity: VisualDensity.compact,
                          onPressed: () =>
                              unawaited(service.stopAndClear()),
                          icon: const Icon(
                            Icons.close,
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                _MiniProgress(player: service.player),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _MiniProgress extends StatelessWidget {
  const _MiniProgress({required this.player});

  final AudioPlayer player;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration?>(
      stream: player.durationStream,
      builder: (context, durationSnap) {
        final duration = durationSnap.data ?? Duration.zero;
        return StreamBuilder<Duration>(
          stream: player.positionStream,
          builder: (context, positionSnap) {
            final position = positionSnap.data ?? Duration.zero;
            final total = duration.inMilliseconds;
            final value = total <= 0
                ? 0.0
                : (position.inMilliseconds / total).clamp(0.0, 1.0);
            return LinearProgressIndicator(
              value: value,
              minHeight: 2,
              backgroundColor: Colors.white12,
              valueColor:
                  const AlwaysStoppedAnimation<Color>(Color(0xFF52C41A)),
            );
          },
        );
      },
    );
  }
}
