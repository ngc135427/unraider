import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import 'video_wake_lock.dart';

const _playbackSpeeds = <double>[0.5, 0.75, 1, 1.25, 1.5, 2];
const _seekStep = Duration(seconds: 10);

/// Compact controls shared by all video preview surfaces.
class VideoPlaybackControls extends StatelessWidget {
  const VideoPlaybackControls({
    super.key,
    required this.controller,
    required this.value,
    this.onFullscreen,
    this.fullscreen = false,
  });

  final VideoPlayerController controller;
  final VideoPlayerValue value;
  final VoidCallback? onFullscreen;
  final bool fullscreen;

  void _seekBy(Duration offset) {
    final targetMilliseconds =
        (value.position.inMilliseconds + offset.inMilliseconds)
            .clamp(0, value.duration.inMilliseconds)
            .toInt();
    unawaited(
      controller.seekTo(Duration(milliseconds: targetMilliseconds)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final speedLabel = _formatSpeed(value.playbackSpeed);
    return Row(
      children: [
        _VideoControlButton(
          tooltip: '后退 10 秒',
          onPressed: () => _seekBy(-_seekStep),
          icon: Icons.replay_10,
        ),
        _VideoControlButton(
          tooltip: value.isPlaying ? '暂停' : '播放',
          onPressed: () {
            if (value.isPlaying) {
              unawaited(controller.pause());
            } else {
              unawaited(controller.play());
            }
          },
          icon: value.isPlaying
              ? Icons.pause_circle_filled
              : Icons.play_circle_filled,
          iconSize: 34,
        ),
        _VideoControlButton(
          tooltip: '前进 10 秒',
          onPressed: () => _seekBy(_seekStep),
          icon: Icons.forward_10,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            '${_formatDuration(value.position)} / '
            '${_formatDuration(value.duration)}',
            maxLines: 1,
            overflow: TextOverflow.fade,
            softWrap: false,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ),
        PopupMenuButton<double>(
          tooltip: '播放速度（当前 $speedLabel 倍）',
          initialValue: value.playbackSpeed,
          onSelected: (speed) {
            unawaited(controller.setPlaybackSpeed(speed));
          },
          itemBuilder: (context) => _playbackSpeeds
              .map(
                (speed) => CheckedPopupMenuItem<double>(
                  value: speed,
                  checked: (speed - value.playbackSpeed).abs() < 0.01,
                  child: Text('${_formatSpeed(speed)} 倍'),
                ),
              )
              .toList(growable: false),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${speedLabel}x',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Icon(
                  Icons.arrow_drop_down,
                  color: Colors.white70,
                  size: 18,
                ),
              ],
            ),
          ),
        ),
        if (onFullscreen != null)
          _VideoControlButton(
            tooltip: fullscreen ? '退出全屏' : '全屏播放',
            onPressed: onFullscreen!,
            icon: fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
            width: 38,
          ),
      ],
    );
  }
}

/// Opens [controller] in an immersive route while preserving its playback
/// position, speed and play/pause state.
Future<void> openVideoFullscreen(
  BuildContext context,
  VideoPlayerController controller,
) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _FullscreenVideoPage(controller: controller),
    ),
  );
}

class _FullscreenVideoPage extends StatefulWidget {
  const _FullscreenVideoPage({required this.controller});

  final VideoPlayerController controller;

  @override
  State<_FullscreenVideoPage> createState() => _FullscreenVideoPageState();
}

class _FullscreenVideoPageState extends State<_FullscreenVideoPage> {
  bool get _supportsOrientationLock =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void initState() {
    super.initState();
    unawaited(
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
    if (_supportsOrientationLock && widget.controller.value.aspectRatio >= 1) {
      unawaited(
        SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]),
      );
    }
  }

  @override
  void dispose() {
    if (_supportsOrientationLock) {
      unawaited(
        SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]),
      );
    }
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  void _togglePlayback() {
    if (widget.controller.value.isPlaying) {
      unawaited(widget.controller.pause());
    } else {
      unawaited(widget.controller.play());
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        alignment: Alignment.center,
        children: [
          Center(
            child: ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: controller,
              builder: (context, value, _) {
                return AspectRatio(
                  aspectRatio:
                      value.aspectRatio == 0 ? 16 / 9 : value.aspectRatio,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onDoubleTap: _togglePlayback,
                    child: VideoWakeLock(
                      controller: controller,
                      child: VideoPlayer(controller),
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
            child: SafeArea(
              top: false,
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.58),
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
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      child: ValueListenableBuilder<VideoPlayerValue>(
                        valueListenable: controller,
                        builder: (context, value, _) {
                          return VideoPlaybackControls(
                            controller: controller,
                            value: value,
                            fullscreen: true,
                            onFullscreen: () => Navigator.of(context).pop(),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: SafeArea(
              child: IconButton(
                tooltip: '退出全屏',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _VideoControlButton extends StatelessWidget {
  const _VideoControlButton({
    required this.tooltip,
    required this.onPressed,
    required this.icon,
    this.iconSize = 25,
    this.width = 42,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final IconData icon;
  final double iconSize;
  final double width;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      constraints: BoxConstraints.tightFor(width: width, height: 42),
      icon: Icon(icon, color: Colors.white, size: iconSize),
    );
  }
}

String _formatDuration(Duration value) {
  final total = value.inSeconds;
  final seconds = (total % 60).toString().padLeft(2, '0');
  final minutes = ((total ~/ 60) % 60).toString().padLeft(2, '0');
  final hours = total ~/ 3600;
  if (hours > 0) {
    return '$hours:$minutes:$seconds';
  }
  return '$minutes:$seconds';
}

String _formatSpeed(double speed) {
  if (speed == speed.roundToDouble()) {
    return speed.toStringAsFixed(0);
  }
  if (speed * 10 == (speed * 10).roundToDouble()) {
    return speed.toStringAsFixed(1);
  }
  return speed.toStringAsFixed(2);
}
