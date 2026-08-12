import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unraider/widgets/video_playback_controls.dart';
import 'package:video_player/video_player.dart';

void main() {
  testWidgets('video controls fit a narrow preview and show playback actions', (
    tester,
  ) async {
    var fullscreenTapped = false;
    final controller = VideoPlayerController.networkUrl(
      Uri.parse('https://example.com/video.mp4'),
    );
    addTearDown(controller.dispose);

    const value = VideoPlayerValue(
      duration: Duration(minutes: 10),
      position: Duration(minutes: 1, seconds: 2),
      isInitialized: true,
      isPlaying: true,
      playbackSpeed: 1.25,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          color: Colors.black,
          child: Center(
            child: SizedBox(
              width: 292,
              child: VideoPlaybackControls(
                controller: controller,
                value: value,
                onFullscreen: () => fullscreenTapped = true,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.replay_10), findsOneWidget);
    expect(find.byIcon(Icons.pause_circle_filled), findsOneWidget);
    expect(find.byIcon(Icons.forward_10), findsOneWidget);
    expect(find.text('01:02 / 10:00'), findsOneWidget);
    expect(find.text('1.25x'), findsOneWidget);
    expect(find.byIcon(Icons.fullscreen), findsOneWidget);
    await tester.tap(find.byIcon(Icons.fullscreen));
    expect(fullscreenTapped, isTrue);
    expect(tester.takeException(), isNull);
  });
}
