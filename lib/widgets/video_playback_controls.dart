import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

const _playbackSpeeds = <double>[0.5, 0.75, 1, 1.25, 1.5, 2];
const _seekStep = Duration(seconds: 10);

/// Compact controls shared by all video preview surfaces.
class VideoPlaybackControls extends StatelessWidget {
  const VideoPlaybackControls({
    super.key,
    required this.controller,
    required this.value,
  });

  final VideoPlayerController controller;
  final VideoPlayerValue value;

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
        const SizedBox(width: 6),
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
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
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
      ],
    );
  }
}

class _VideoControlButton extends StatelessWidget {
  const _VideoControlButton({
    required this.tooltip,
    required this.onPressed,
    required this.icon,
    this.iconSize = 25,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final IconData icon;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 42, height: 42),
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
