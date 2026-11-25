import 'dart:async';

import 'package:baha_plus/core/models.dart';
import 'package:baha_plus/core/playback_state.dart';
import 'package:baha_plus/data/app_store.dart';
import 'package:baha_plus/data/native_playback.dart';
import 'package:baha_plus/main.dart';
import 'package:baha_plus/ui/native_video_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';

import 'core_test.dart' show FakeSearch, MemoryStorage;
import 'fake_account.dart';
import 'fake_metadata.dart';
import 'fake_playback.dart';

void main() {
  const channel = MethodChannel('app.bahaplus.mobile/picture_in_picture');
  const mediaSource = 'https://bahamut.akamaized.net/fixture.m3u8';
  const content = PlaybackState(
    phase: PlaybackPhase.content,
    surfaceReady: true,
    paused: false,
    duration: 1200,
    position: 300,
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('picture in picture keeps the current session', (tester) async {
      tester.view.physicalSize = const Size(400, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final messages = <MethodCall>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        messages.add(call);
        return switch (call.method) {
          'isSupported' || 'enter' => true,
          _ => null,
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final commands = <String>[];
      final store = (await tester.runAsync(
        () => AppStore.create(
          nativeHttpApiFactory: PendingNativeHttpApi.new,
          metadataApi: FakeMetadata(),
          accountApi: FakeAccountApi(),
          storage: MemoryStorage(),
          animeSearch: FakeSearch(),
        ),
      ))!;
      addTearDown(store.dispose);
      await playFixture(
        store,
        const Anime(
          id: '10',
          title: 'Test Anime',
          cover: 'https://p2.bahamut.com.tw/10.jpg',
          latestVideoId: '20',
        ),
        onCommand: (action, _) async {
          commands.add(action);
          return true;
        },
      );

      final session = store.nativeHttpPlayback!;
      final video = VideoPlayerController.networkUrl(Uri.parse(mediaSource))
        ..value = const VideoPlayerValue(
          duration: Duration(minutes: 20),
          size: Size(1920, 1080),
          isInitialized: true,
        );
      session.player = NativePlayback(
        document: store.operation.id,
        source: NativePlaybackSource.fromJson({
          'master': mediaSource,
          'variants': <Json>[],
          'position': 300,
          'duration': 1200,
          'rate': 1,
          'paused': false,
          'muted': false,
        }),
        userAgent: 'Test',
        onState: (_) {},
      )..video = video;

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      store.playback.value = const PlaybackState(
        phase: PlaybackPhase.advertisement,
        surfaceReady: true,
        duration: 30,
      );
      await tester.pumpWidget(BahaPlusApp(store: store));
      await tester.pump();
      final button = find.byKey(const ValueKey('player-picture-in-picture'));
      expect(button, findsNothing);

      store.playback.value = content;
      await tester.pump();
      final surface = find.byType(NativeVideoSurface);
      final surfaceState = tester.state(surface);
      await tester.tap(button);
      await tester.pump();
      final enter = messages.singleWhere((call) => call.method == 'enter');
      final arguments = enter.arguments as Map;
      final id = arguments['id'];
      expect(arguments['document'], store.operation.id);
      if (platform == TargetPlatform.android) {
        expect(arguments['aspectRatio'], closeTo(16 / 9, .001));
      } else {
        expect(arguments, {
          'id': id,
          'document': store.operation.id,
          'source': mediaSource,
        });
      }

      Future<void> hostEvent(String method, Map<String, Object?> data) async {
        final reply = Completer<void>();
        await messenger.handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(MethodCall(method, data)),
          (_) => reply.complete(),
        );
        await reply.future;
        await tester.pump();
      }

      await hostEvent('modeChanged', {'id': id, 'active': true});
      expect(button, findsNothing);
      expect(tester.state(surface), same(surfaceState));
      expect(session.player!.video, same(video));

      final playerPage = find.byKey(const ValueKey('native-player-page'));
      if (platform == TargetPlatform.android) {
        expect(playerPage, findsNothing);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        expect(commands, isEmpty);
      } else {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        await tester.pump();
        expect(store.applicationActive, isFalse);
        expect(store.playbackActive, isTrue);
        expect(commands, isEmpty);
        await hostEvent('playingChanged', {'id': 'stale', 'playing': false});
        await hostEvent('playingChanged', {'id': id, 'playing': true});
        expect(commands, ['play']);
      }

      await hostEvent('modeChanged', {'id': id, 'active': false});
      if (platform == TargetPlatform.android) {
        expect(playerPage, findsOneWidget);
        expect(tester.state(surface), same(surfaceState));
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        await tester.pump();
      }
      expect(store.playbackActive, isFalse);
      expect(store.playback.value.paused, isTrue);
      expect(store.playback.value.position, content.position);
      expect(commands.last, 'pause');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(store.playback.value.paused, isTrue);

      tester.view.physicalSize = const Size(850, 400);
      store.setPlayerFullscreen(true);
      store.playback.value = content;
      await tester.pump();
      expect(tester.state(surface), same(surfaceState));

      await tester.tap(button);
      await tester.pump();
      final landscapeEnter = messages.lastWhere(
        (call) => call.method == 'enter',
      );
      final landscapeArguments = landscapeEnter.arguments as Map;
      final landscapeId = landscapeArguments['id'];
      expect(landscapeId, isNot(id));
      expect(landscapeArguments['document'], store.operation.id);
      if (platform == TargetPlatform.android) {
        expect(landscapeArguments['aspectRatio'], closeTo(16 / 9, .001));
        expect(landscapeArguments['right'], greaterThan(arguments['right']));
      } else {
        expect(landscapeArguments, {
          'id': landscapeId,
          'document': store.operation.id,
          'source': mediaSource,
        });
      }

      await hostEvent('modeChanged', {'id': id, 'active': false});
      expect(button, findsNothing);
      await hostEvent('modeChanged', {'id': landscapeId, 'active': true});
      expect(tester.state(surface), same(surfaceState));
      expect(session.player!.video, same(video));
      expect(store.playback.value.position, content.position);
      await hostEvent('modeChanged', {'id': landscapeId, 'active': false});
      expect(button, findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: TargetPlatformVariant({platform}));
  }
}
