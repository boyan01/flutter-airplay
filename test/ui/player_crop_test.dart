// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_airplay/l10n/generated/app_localizations.dart';
import 'package:flutter_airplay/platform/window_controller.dart';
import 'package:flutter_airplay/receiver/receiver_model.dart';
import 'package:flutter_airplay/ui/playback/player_page.dart';
import 'package:flutter_airplay/ui/playback/video_crop_editor.dart';
import 'package:flutter_airplay/ui/tv_focus.dart';
import 'package:flutter_test/flutter_test.dart';

import '../receiver/fake_receiver.dart';

void main() {
  const channel = MethodChannel('tech.soit.flutterairplay/window');
  const crop = Rect.fromLTWH(.25, .125, .5, .75);
  late FakeReceiver backend;
  late ReceiverModel model;
  late List<MethodCall> calls;
  var escapes = 0;

  Future<void> mount(
    WidgetTester tester, {
    String platform = 'windows',
    bool native = false,
    bool television = false,
    Rect initialCrop = ReceiverModel.fullVideoCrop,
  }) async {
    calls = [];
    escapes = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return null;
    });
    await tester.binding.setSurfaceSize(const Size(800, 600));
    backend = FakeReceiver(
      autoStart: false,
      capabilities: {
        'platform': platform,
        'nativeVideoSurface': native,
        'isTelevision': television,
      },
    );
    model = ReceiverModel(backend);
    await model.initialize();
    frame(backend, 1920, 1080);
    model.setVideoCrop(initialCrop);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      await backend.controller.close();
      await tester.binding.setSurfaceSize(null);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: TvFocusScope(
            enabled: television,
            child: ListenableBuilder(
              listenable: model,
              builder: (context, _) => PlayerPage(
                model: model,
                window: const WindowController(),
                onFullscreen: () {},
                onEscape: () => escapes++,
                dialogOpen: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> edit(WidgetTester tester) async {
    if (find.byKey(const Key('cropVideo')).evaluate().isEmpty) {
      await tester.tapAt(const Offset(400, 300));
      // Desktop single taps wait for the double-tap recognizer to expire.
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(const Key('cropVideo')));
    await tester.pumpAndSettle();
    expect(find.byType(VideoCropEditor), findsOneWidget);
  }

  testWidgets('TV remote opens crop from player and edits the selection', (
    tester,
  ) async {
    await mount(
      tester,
      platform: 'android',
      native: true,
      television: true,
      initialCrop: crop,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(VideoCropEditor), findsOneWidget);
    final move = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Move frame'),
    );
    expect(move.focusNode!.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    final selection = find.byKey(const Key('cropSelection'));
    final before = tester.getRect(selection);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(tester.getRect(selection).left, greaterThan(before.left));
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(move.focusNode!.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    final resize = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Resize frame'),
    );
    expect(resize.focusNode!.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    final moved = tester.getRect(selection);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(tester.getRect(selection).width, lessThan(moved.width));

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(VideoCropEditor), findsNothing);
    expect(model.videoCrop, crop);
    expect(escapes, 0);
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('cropVideo')))
          .focusNode!
          .hasPrimaryFocus,
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Move frame'),
          )
          .focusNode!
          .hasPrimaryFocus,
      isTrue,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  });

  VideoCropEditor editor(WidgetTester tester) =>
      tester.widget<VideoCropEditor>(find.byType(VideoCropEditor));

  for (final platform in ['macos', 'windows', 'linux']) {
    for (final exit in ['apply', 'cancel', 'rotation']) {
      testWidgets(
        '$platform controls auto-hide after crop $exit with a stationary mouse',
        (tester) async {
          await mount(
            tester,
            platform: platform,
            native: platform == 'macos',
            initialCrop: crop,
          );
          await edit(tester);
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          addTearDown(mouse.removePointer);
          final location = exit == 'rotation'
              ? const Offset(400, 300)
              : tester.getCenter(
                  find.text(exit == 'apply' ? 'Apply crop' : 'Cancel'),
                );
          await mouse.addPointer(location: location);
          if (exit == 'rotation') {
            frame(backend, 1080, 1920);
          } else {
            await mouse.down(location);
            await mouse.up();
          }
          await tester.pumpAndSettle();
          expect(find.byType(VideoCropEditor), findsNothing);
          expect(find.byKey(const Key('playerControls')), findsOneWidget);
          await tester.pump(const Duration(seconds: 3));
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('playerControls')), findsNothing);
          expect(
            RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(
              1,
            ),
            SystemMouseCursors.none,
          );
          await mouse.moveTo(const Offset(401, 300));
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('playerControls')), findsOneWidget);
        },
      );
    }
  }

  for (final key in [
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.escape,
  ]) {
    testWidgets('keyboard crop exit restores entry focus ($key)', (
      tester,
    ) async {
      await mount(tester, initialCrop: crop);
      await edit(tester);
      Focus.of(tester.element(find.text('Apply crop'))).requestFocus();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
      expect(find.byType(VideoCropEditor), findsNothing);
      final entry = tester.widget<ButtonStyleButton>(
        find.byKey(const Key('cropVideo')),
      );
      expect(entry.focusNode!.hasPrimaryFocus, isTrue);
      await tester.pump(const Duration(seconds: 6));
      expect(find.byKey(const Key('playerControls')), findsOneWidget);
    });
  }

  Rect textureViewport(WidgetTester tester) => tester.getRect(
    find
        .ancestor(of: find.byType(Texture), matching: find.byType(ClipRect))
        .first,
  );

  void expectTextureCrop(WidgetTester tester, Rect selection) {
    final viewport = textureViewport(tester);
    final texture = tester.getRect(find.byType(Texture));
    expect(
      viewport.width / viewport.height,
      closeTo(1920 * selection.width / (1080 * selection.height), .0001),
    );
    expect(texture.width, closeTo(viewport.width / selection.width, .0001));
    expect(texture.height, closeTo(viewport.height / selection.height, .0001));
    expect(
      texture.left,
      closeTo(viewport.left - selection.left * texture.width, .0001),
    );
    expect(
      texture.top,
      closeTo(viewport.top - selection.top * texture.height, .0001),
    );
    expect(texture.width / texture.height, closeTo(1920 / 1080, .0001));
    expect(tester.widget<Texture>(find.byType(Texture)).textureId, 0);
  }

  List<MethodCall> presentations() =>
      calls.where((call) => call.method == 'setVideoPresentation').toList();

  Map<String, Object> arguments(
    Rect selection, {
    int width = 1920,
    int height = 1080,
    Rect? viewport,
  }) {
    final fitted = applyBoxFit(
      BoxFit.contain,
      Size(width * selection.width, height * selection.height),
      const Size(800, 600),
    ).destination;
    final frame =
        viewport ??
        Alignment.center.inscribe(fitted, const Rect.fromLTWH(0, 0, 800, 600));
    return {
      'left': selection.left,
      'top': selection.top,
      'width': selection.width,
      'height': selection.height,
      'sourceWidth': width,
      'sourceHeight': height,
      'viewportLeft': closeTo(frame.left / 800, .000001),
      'viewportTop': closeTo(frame.top / 600, .000001),
      'viewportWidth': closeTo(frame.width / 800, .000001),
      'viewportHeight': closeTo(frame.height / 600, .000001),
    };
  }

  for (final platform in ['windows', 'linux', 'ios', 'android', 'macos']) {
    testWidgets(
      '$platform cropVideo opens a full-source editor with the current selection',
      (tester) async {
        final native = platform == 'macos' || platform == 'android';
        await mount(
          tester,
          platform: platform,
          native: native,
          initialCrop: crop,
        );
        await edit(tester);
        expect(editor(tester).initialCrop, crop);
        expect(editor(tester).sourceWidth, 1920);
        expect(editor(tester).sourceHeight, 1080);
        expect(model.videoCrop, crop);
        if (native) {
          final surface = tester.getSize(
            find.byKey(const Key('nativeVideoSurface')),
          );
          expect(surface.width, lessThan(800));
          expect(surface.width / surface.height, closeTo(1920 / 1080, .0001));
          final selection = tester.getRect(
            find.byKey(const Key('cropSelection')),
          );
          final frame = tester.getRect(
            find.byKey(const Key('nativeVideoSurface')),
          );
          expect(
            selection.left,
            closeTo(frame.left + crop.left * frame.width, .001),
          );
          expect(
            selection.bottom,
            closeTo(frame.top + crop.bottom * frame.height, .001),
          );
        } else {
          expectTextureCrop(tester, ReceiverModel.fullVideoCrop);
        }
        editor(tester).onCancel();
        await tester.pumpAndSettle();
        expect(find.byType(VideoCropEditor), findsNothing);
        expect(model.videoCrop, crop);
        expect(backend.stops, 0);
        expect(backend.saves, 0);
      },
    );
  }

  testWidgets(
    'texture crop clips and offsets the full source without stretching it',
    (tester) async {
      await mount(tester, initialCrop: crop);
      expectTextureCrop(tester, crop);
      expect(textureViewport(tester).center, const Offset(400, 300));
      expect(presentations(), isEmpty);
    },
  );

  testWidgets(
    'apply commits the editor selection, cancel retains it, and reset restores full video',
    (tester) async {
      await mount(tester);
      await edit(tester);
      // Exercise the player/editor boundary; editor gestures have a separate suite.
      editor(tester).onApply(crop);
      await tester.pumpAndSettle();
      expect(find.byType(VideoCropEditor), findsNothing);
      expect(model.videoCrop, crop);
      expectTextureCrop(tester, crop);
      await edit(tester);
      expect(editor(tester).initialCrop, crop);
      editor(tester).onCancel();
      await tester.pumpAndSettle();
      expect(model.videoCrop, crop);
      expectTextureCrop(tester, crop);
      await edit(tester);
      await tester.tap(find.byKey(const Key('cropReset')));
      await tester.pumpAndSettle();
      expect(model.videoCrop, crop);
      expect(find.byType(VideoCropEditor), findsOneWidget);
      await tester.tap(find.text('Apply crop'));
      await tester.pumpAndSettle();
      expect(find.byType(VideoCropEditor), findsNothing);
      expect(model.videoCrop, ReceiverModel.fullVideoCrop);
      expectTextureCrop(tester, ReceiverModel.fullVideoCrop);
      expect(backend.stops, 0);
      expect(backend.saves, 0);
      expect(escapes, 0);
    },
  );

  testWidgets(
    'TV exposes the shared crop entry and passes television mode to the editor',
    (tester) async {
      await mount(tester, platform: 'android', native: true, television: true);
      await edit(tester);
      expect(editor(tester).television, isTrue);
      editor(tester).onCancel();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('continueWatching')), findsOneWidget);
      expect(backend.stops, 0);
    },
  );

  testWidgets(
    'macOS host receives selected crop, full frame while editing, and applied crop',
    (tester) async {
      await mount(tester, platform: 'macos', native: true, initialCrop: crop);
      expect(presentations().single.arguments, arguments(crop));
      await edit(tester);
      final editingViewport = tester.getRect(
        find.byKey(const Key('nativeVideoSurface')),
      );
      expect(
        presentations().last.arguments,
        arguments(ReceiverModel.fullVideoCrop, viewport: editingViewport),
      );
      const applied = Rect.fromLTWH(.1, .2, .7, .6);
      editor(tester).onApply(applied);
      await tester.pumpAndSettle();
      expect(model.videoCrop, applied);
      expect(presentations().map((call) => call.arguments), [
        arguments(crop),
        arguments(ReceiverModel.fullVideoCrop, viewport: editingViewport),
        arguments(applied),
      ]);
      final surface = tester.getSize(
        find.byKey(const Key('nativeVideoSurface')),
      );
      expect(
        surface.width / surface.height,
        closeTo(1920 * .7 / (1080 * .6), .0001),
      );
      expect(find.byType(Texture), findsNothing);
      await edit(tester);
      editor(tester).onCancel();
      await tester.pumpAndSettle();
      expect(presentations().last.arguments, arguments(applied));
      await edit(tester);
      await tester.tap(find.byKey(const Key('cropReset')));
      await tester.pumpAndSettle();
      expect(model.videoCrop, applied);
      await tester.tap(find.text('Apply crop'));
      await tester.pumpAndSettle();
      expect(model.videoCrop, ReceiverModel.fullVideoCrop);
      expect(
        presentations().last.arguments,
        arguments(ReceiverModel.fullVideoCrop),
      );
    },
  );

  testWidgets('system Back cancels crop editing without escaping the player', (
    tester,
  ) async {
    await mount(tester, platform: 'macos', native: true, initialCrop: crop);
    await edit(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(VideoCropEditor), findsNothing);
    expect(find.byType(PlayerPage), findsOneWidget);
    expect(model.videoCrop, crop);
    expect(presentations().last.arguments, arguments(crop));
    expect(escapes, 0);
    expect(backend.stops, 0);
  });

  testWidgets(
    'native presentation failure restores full video and reports the host error',
    (tester) async {
      await mount(tester, platform: 'macos', native: true);
      await edit(tester);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        if (call.method == 'setVideoPresentation' &&
            (call.arguments as Map)['width'] == crop.width) {
          throw PlatformException(
            code: 'presentation_failed',
            message: 'Host rejected crop',
          );
        }
        return null;
      });
      editor(tester).onApply(crop);
      await tester.pumpAndSettle();
      expect(find.byType(VideoCropEditor), findsNothing);
      expect(model.videoCrop, ReceiverModel.fullVideoCrop);
      expect(model.commandError, 'Host rejected crop');
      expect(model.notice, 'Host rejected crop');
      expect(
        presentations().last.arguments,
        arguments(ReceiverModel.fullVideoCrop),
      );
      final context = tester.element(find.byType(PlayerPage));
      expect(
        find.text(AppLocalizations.of(context)!.cropFailed),
        findsOneWidget,
      );
      expect(backend.stops, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'native crop updates do not use rounded rectangle descriptions as identity',
    (tester) async {
      await mount(tester, platform: 'macos', native: true, initialCrop: crop);
      const adjusted = Rect.fromLTWH(.25001, .125, .5, .75);
      expect(adjusted.toString(), crop.toString());
      model.setVideoCrop(adjusted);
      await tester.pumpAndSettle();
      expect(presentations().last.arguments, arguments(adjusted));
      expect(presentations(), hasLength(2));
    },
  );

  testWidgets(
    'macOS updates source dimensions while retaining crop at the same aspect',
    (tester) async {
      await mount(tester, platform: 'macos', native: true, initialCrop: crop);
      frame(backend, 1280, 720);
      await tester.pumpAndSettle();
      expect(model.videoCrop, crop);
      expect(
        presentations().last.arguments,
        arguments(crop, width: 1280, height: 720),
      );
      frame(backend, 720, 1280);
      await tester.pumpAndSettle();
      expect(model.videoCrop, ReceiverModel.fullVideoCrop);
      expect(
        presentations().last.arguments,
        arguments(ReceiverModel.fullVideoCrop, width: 720, height: 1280),
      );
    },
  );
  for (final native in [false, true]) {
    testWidgets(
      'preview uses the draft without saving and Back returns to editing (native=$native)',
      (tester) async {
        await mount(
          tester,
          platform: native ? 'macos' : 'windows',
          native: native,
          initialCrop: crop,
        );
        await edit(tester);
        await tester.drag(
          find.byKey(const Key('cropSelection')),
          const Offset(25, 10),
        );
        await tester.pumpAndSettle();
        final draft = tester.getRect(find.byKey(const Key('cropSelection')));
        final area = tester.getRect(find.byKey(const Key('cropEditingArea')));
        await tester.tap(find.byKey(const Key('cropPreview')));
        await tester.pumpAndSettle();
        expect(editor(tester).previewing, isTrue);
        expect(find.byKey(const Key('cropSelection')), findsNothing);
        expect(tester.getRect(find.byKey(const Key('cropEditingArea'))), area);
        expect(model.videoCrop, crop);
        final previewTexture = native
            ? null
            : tester.getRect(find.byType(Texture));
        final previewArgs = native
            ? Map.of(presentations().last.arguments as Map)
            : null;
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(editor(tester).previewing, isFalse);
        expect(tester.getRect(find.byKey(const Key('cropSelection'))), draft);
        await tester.tap(find.byKey(const Key('cropPreview')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Apply crop'));
        await tester.pumpAndSettle();
        expect(find.byType(VideoCropEditor), findsNothing);
        expect(model.videoCrop, isNot(crop));
        if (native) {
          final applied = presentations().last.arguments as Map;
          for (final key in ['left', 'top', 'width', 'height']) {
            expect(applied[key], previewArgs![key]);
          }
        } else {
          expectTextureCrop(tester, model.videoCrop);
          final texture = tester.getRect(find.byType(Texture));
          expect(
            texture.width / texture.height,
            closeTo(previewTexture!.width / previewTexture.height, .000001),
          );
        }
        final entry = tester.widget<ButtonStyleButton>(
          find.byKey(const Key('cropVideo')),
        );
        expect(entry.focusNode!.hasFocus, isFalse);
        expect(backend.stops, 0);
      },
    );

    testWidgets(
      'cancel from preview restores the saved crop (native=$native)',
      (tester) async {
        await mount(
          tester,
          platform: native ? 'macos' : 'windows',
          native: native,
          initialCrop: crop,
        );
        await edit(tester);
        await tester.tap(find.byKey(const Key('cropReset')));
        await tester.tap(find.byKey(const Key('cropPreview')));
        await tester.pumpAndSettle();
        expect(model.videoCrop, crop);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.byType(VideoCropEditor), findsNothing);
        expect(model.videoCrop, crop);
        if (native) {
          expect(presentations().last.arguments, arguments(crop));
        } else {
          expectTextureCrop(tester, crop);
        }
      },
    );
  }

  testWidgets(
    'source rotation dismisses the active ratio menu with its editor',
    (tester) async {
      await mount(tester, initialCrop: crop);
      await edit(tester);
      await tester.tap(find.byKey(const Key('cropRatio')));
      await tester.pumpAndSettle();
      expect(find.byType(PopupMenuItem<bool>), findsNWidgets(2));
      frame(backend, 1080, 1920);
      await tester.pumpAndSettle();
      expect(find.byType(VideoCropEditor), findsNothing);
      expect(find.byType(PopupMenuItem<bool>), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('source rotation exits preview safely and restores full video', (
    tester,
  ) async {
    await mount(tester, platform: 'macos', native: true, initialCrop: crop);
    await edit(tester);
    await tester.tap(find.byKey(const Key('cropPreview')));
    await tester.pumpAndSettle();
    frame(backend, 1080, 1920);
    await tester.pumpAndSettle();
    expect(find.byType(VideoCropEditor), findsNothing);
    expect(model.videoCrop, ReceiverModel.fullVideoCrop);
    expect(
      presentations().last.arguments,
      arguments(ReceiverModel.fullVideoCrop, width: 1080, height: 1920),
    );
    expect(backend.stops, 0);
  });

  testWidgets(
    'preview presentation failure retains the previously saved crop',
    (tester) async {
      await mount(tester, platform: 'macos', native: true, initialCrop: crop);
      await edit(tester);
      await tester.drag(
        find.byKey(const Key('cropSelection')),
        const Offset(25, 10),
      );
      await tester.pumpAndSettle();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        if (call.method == 'setVideoPresentation' &&
            (call.arguments as Map)['left'] != crop.left) {
          throw PlatformException(
            code: 'presentation_failed',
            message: 'Preview unavailable',
          );
        }
        return null;
      });
      await tester.tap(find.byKey(const Key('cropPreview')));
      await tester.pumpAndSettle();
      expect(find.byType(VideoCropEditor), findsNothing);
      expect(model.videoCrop, crop);
      expect(presentations().last.arguments, arguments(crop));
    },
  );
  for (final platform in ['macos', 'windows', 'linux']) {
    testWidgets(
      '$platform keeps the pointer visible throughout crop editing and preview',
      (tester) async {
        await mount(
          tester,
          platform: platform,
          native: platform == 'macos',
          initialCrop: crop,
        );
        await edit(tester);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(mouse.removePointer);
        final area = tester.getRect(find.byKey(const Key('cropEditingArea')));
        await mouse.addPointer(location: area.topLeft + const Offset(8, 8));
        await tester.pump();
        MouseCursor? cursor() =>
            RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);
        expect(cursor(), SystemMouseCursors.basic);
        await tester.pump(const Duration(seconds: 6));
        expect(cursor(), SystemMouseCursors.basic);
        expect(find.byKey(const Key('playerControls')), findsNothing);
        await mouse.moveTo(
          tester.getCenter(find.byKey(const Key('cropSelection'))),
        );
        await tester.pump();
        expect(cursor(), SystemMouseCursors.grab);
        await mouse.moveTo(
          tester.getCenter(find.byKey(const Key('cropCorner3'))),
        );
        await tester.pump();
        expect(cursor(), SystemMouseCursors.resizeUpLeftDownRight);
        await tester.tap(find.byKey(const Key('cropPreview')));
        await mouse.moveTo(area.center);
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 6));
        expect(cursor(), SystemMouseCursors.basic);
        expect(find.byKey(const Key('playerControls')), findsNothing);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        await tester.tapAt(area.center);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        expect(cursor(), SystemMouseCursors.none);
        await mouse.moveTo(area.center + const Offset(1, 0));
        await tester.pumpAndSettle();
        expect(cursor(), SystemMouseCursors.basic);
      },
    );
  }
}
