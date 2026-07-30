import 'dart:async';

import 'package:flutter/material.dart';

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
        final title = _titleOf(track.name);
        final subtitle = service.error ??
            (service.loading ? '正在流式缓冲…' : service.rootPath);
        return Padding(
          padding: EdgeInsets.fromLTRB(12, 0, 12, 8 + bottomOffset),
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(14),
            color: const Color(0xFF1B2A41),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const MusicPlayerPage(),
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
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
                      tooltip: service.playing ? '暂停' : '播放',
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
                      tooltip: '关闭播放器',
                      onPressed: () => unawaited(service.stopAndClear()),
                      icon: const Icon(Icons.close, color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  static String _titleOf(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot <= 0) {
      return fileName;
    }
    return fileName.substring(0, dot);
  }
}


