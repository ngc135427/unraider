import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Keeps the screen awake while the wrapped video controller is playing.
///
/// A shared holder set prevents one preview page from disabling the wake lock
/// while another page is still playing during page transitions.
class VideoWakeLock extends StatefulWidget {
  const VideoWakeLock({
    super.key,
    required this.controller,
    required this.child,
  });

  final VideoPlayerController controller;
  final Widget child;

  @override
  State<VideoWakeLock> createState() => _VideoWakeLockState();
}

class _VideoWakeLockState extends State<VideoWakeLock> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncWakeLock);
    _syncWakeLock();
  }

  @override
  void didUpdateWidget(covariant VideoWakeLock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) {
      return;
    }
    oldWidget.controller.removeListener(_syncWakeLock);
    _VideoWakeLockCoordinator.instance.setHeld(this, false);
    widget.controller.addListener(_syncWakeLock);
    _syncWakeLock();
  }

  void _syncWakeLock() {
    _VideoWakeLockCoordinator.instance.setHeld(
      this,
      widget.controller.value.isPlaying,
    );
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncWakeLock);
    _VideoWakeLockCoordinator.instance.setHeld(this, false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _VideoWakeLockCoordinator {
  _VideoWakeLockCoordinator._();

  static final instance = _VideoWakeLockCoordinator._();

  final Set<Object> _holders = <Object>{};
  Future<void> _pendingUpdate = Future<void>.value();
  bool _enabled = false;

  void setHeld(Object holder, bool held) {
    if (held) {
      _holders.add(holder);
    } else {
      _holders.remove(holder);
    }

    final shouldEnable = _holders.isNotEmpty;
    if (shouldEnable == _enabled) {
      return;
    }
    _enabled = shouldEnable;
    _pendingUpdate = _pendingUpdate.then((_) async {
      if (shouldEnable) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    }).onError((_, __) {
      // Playback must remain usable if a platform cannot provide a wake lock.
    });
  }
}
