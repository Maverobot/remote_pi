import 'dart:io';
import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/data/local/boxes.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/voice/speech_service.dart';
import 'package:app/domain/background_progress.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:app/ui/chat/chat_page.dart';
import 'package:app/ui/chat/states/chat_state.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:app/ui/chat/widgets/background_progress_panel.dart';
import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';
import 'extension_ui_test_support.dart';

class _Speech implements SpeechService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Picker implements IImagePickerService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

BackgroundProgress view({
  BackgroundFreshness freshness = BackgroundFreshness.fresh,
  bool truncated = false,
}) => BackgroundProgress(
  sessionId: 'parent',
  epoch: 'epoch',
  truncated: truncated,
  freshness: freshness,
  groups: [
    BackgroundGroup(
      id: 'dispatch',
      label: 'Worker then parallel reviews',
      tasks: [
        const BackgroundTask(
          id: 'a',
          label:
              'Review implementation and confirm behavior with a very long task name 实现审查',
          state: BackgroundTaskState.running,
          elapsed: Duration(seconds: 65),
        ),
        const BackgroundTask(
          id: 'b',
          label: 'Second reviewer',
          state: BackgroundTaskState.paused,
        ),
      ],
    ),
  ],
);

void main() {
  for (final dark in [false, true]) {
    for (final layout in [(320.0, 1.0), (390.0, 1.5), (320.0, 1.5)]) {
      testWidgets(
        'panel collapse, names and stale state: dark=$dark width=${layout.$1} scale=${layout.$2}',
        (tester) async {
          await tester.binding.setSurfaceSize(Size(layout.$1, 800));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          Widget page(BackgroundProgress progress) => MaterialApp(
            theme: dark ? buildDarkTheme() : buildLightTheme(),
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(layout.$1, 800),
                textScaler: TextScaler.linear(layout.$2),
              ),
              child: Scaffold(
                body: Column(
                  children: [
                    const Expanded(child: SizedBox()),
                    BackgroundProgressPanel(progress: progress),
                    const TextField(),
                  ],
                ),
              ),
            ),
          );
          await tester.pumpWidget(page(view()));
          expect(find.text('Background tasks · 2 observed'), findsOneWidget);
          expect(find.text('Second reviewer'), findsNothing);
          await tester.tap(find.text('Background tasks · 2 observed'));
          await tester.pump();
          expect(find.text('Running · 1m 5s'), findsOneWidget);
          expect(find.text('Paused · Elapsed unknown'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(
            page(view(freshness: BackgroundFreshness.offline, truncated: true)),
          );
          expect(find.text('Offline · stale'), findsOneWidget);
          expect(find.text('Some task details omitted'), findsOneWidget);
          expect(find.text('Running · 1m 5s'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('Background tasks · 2 observed'));
          await tester.pump();
          expect(find.text('Second reviewer'), findsNothing);
        },
      );
    }
  }

  for (final dark in [false, true]) {
    for (final layout in [
      (320.0, 640.0, 1.5, 300.0),
      (390.0, 844.0, 1.5, 300.0),
      (320.0, 640.0, 1.0, 300.0),
    ]) {
      testWidgets(
        'keyboard bounds whole panel and preserves composer: $dark $layout',
        (tester) async {
          final size = Size(layout.$1, layout.$2);
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final progress = BackgroundProgress(
            sessionId: 'p',
            epoch: 'e',
            truncated: true,
            freshness: BackgroundFreshness.offline,
            groups: [
              BackgroundGroup(
                id: 'g',
                label: 'Implementation',
                tasks: [
                  for (var i = 0; i < 8; i++)
                    BackgroundTask(
                      id: '$i',
                      label: 'Long background review task number $i',
                      state: BackgroundTaskState.running,
                      elapsed: const Duration(minutes: 2),
                    ),
                ],
              ),
            ],
          );
          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? buildDarkTheme() : buildLightTheme(),
              home: MediaQuery(
                data: MediaQueryData(
                  size: size,
                  viewInsets: EdgeInsets.only(bottom: layout.$4),
                  textScaler: TextScaler.linear(layout.$3),
                ),
                child: Scaffold(
                  body: Column(
                    children: [
                      const SizedBox(height: 56),
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) => Column(
                            children: [
                              const Expanded(child: SizedBox()),
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxHeight: constraints.maxHeight / 2,
                                ),
                                child: BackgroundProgressPanel(
                                  progress: progress,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      InputBar(onSend: (_) {}),
                    ],
                  ),
                ),
              ),
            ),
          );
          final composer = find.descendant(
            of: find.byType(InputBar),
            matching: find.byType(TextField),
          );
          await tester.enterText(composer, 'Keep typing');
          // Tap the visible header within the panel's bounded viewport.
          await tester.tap(find.byType(BackgroundProgressPanel));
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(
            tester.getBottomLeft(find.byType(InputBar)).dy,
            lessThanOrEqualTo(size.height - layout.$4),
          );
          expect(find.text('Keep typing'), findsOneWidget);
          final scroll = find.descendant(
            of: find.byType(BackgroundProgressPanel),
            matching: find.byType(Scrollable),
          );
          await tester.scrollUntilVisible(
            find.text('Long background review task number 7'),
            100,
            scrollable: scroll,
          );
          await tester.pumpAndSettle();
          expect(
            find.text('Long background review task number 7').hitTestable(),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('truncated empty view does not claim all tasks completed', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BackgroundProgressPanel(
            progress: BackgroundProgress(
              sessionId: 'p',
              epoch: 'e',
              truncated: true,
              freshness: BackgroundFreshness.fresh,
              groups: [],
            ),
          ),
        ),
      ),
    );
    expect(find.text('Background tasks · 0 observed'), findsOneWidget);
    expect(find.text('Some task details omitted'), findsOneWidget);
  });

  testWidgets(
    'real sync and viewmodel keep panel above composer after launch; draft survives replacement',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'rp_background_page_',
      );
      await tester.runAsync(() => LocalBoxes.initForTest(directory.path));
      await tester.binding.setSurfaceSize(const Size(390, 640));
      final h = (await tester.runAsync(extensionUiHarness))!;
      await tester.runAsync(() async {
        h.ch.pushControl(
          const RoomAnnounced(peer: 'epk_extui', roomId: 'main', startedAt: 1),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      final voice = VoiceInputViewModel(_Speech());
      final actions = ActionsRepository(h.conn);
      final attach = AttachmentViewModel(_Picker(), actions);
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildDarkTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(viewInsets: const EdgeInsets.only(bottom: 300)),
              child: child!,
            ),
            home: MultiProvider(
              providers: [
                ChangeNotifierProvider<ChatViewModel>.value(value: h.vm),
                ChangeNotifierProvider<Preferences>.value(value: h.prefs),
                ChangeNotifierProvider<VoiceInputViewModel>.value(value: voice),
                ChangeNotifierProvider<AttachmentViewModel>.value(
                  value: attach,
                ),
              ],
              child: const ChatPage(),
            ),
          ),
        );
        final composer = find.descendant(
          of: find.byType(InputBar),
          matching: find.byType(TextField),
        );
        expect(tester.widget<TextField>(composer).enabled, isNot(false));
        await tester.enterText(composer, 'Keep this draft');
        expect(find.text('Keep this draft'), findsOneWidget);
        Future<void> send({bool empty = false}) async {
          await tester.runAsync(() async {
            h.sync.requestSync();
            await Future<void>.delayed(Duration.zero);
            final token = h.ch.sent
                .whereType<Ping>()
                .lastWhere((ping) => ping.backgroundProgress)
                .id;
            h.ch.push(
              Pong(
                inReplyTo: token,
                backgroundProgress: BackgroundProgressMessage(
                  inReplyTo: token,
                  sessionId: 'parent',
                  epoch: 'epoch',
                  available: true,
                  groups: empty ? [] : view().groups,
                ),
              ),
            );
            h.ch.push(
              ToolResult(toolCallId: 'launch', result: 'Async launched'),
            );
            await Future<void>.delayed(const Duration(milliseconds: 50));
          });
          await tester.pump();
        }

        await send();
        expect((h.vm.state as ChatReady).backgroundProgress?.observedCount, 2);
        expect(find.byType(BackgroundProgressPanel), findsOneWidget);
        expect(
          tester.getBottomLeft(find.byType(BackgroundProgressPanel)).dy,
          lessThanOrEqualTo(tester.getTopLeft(find.byType(InputBar)).dy),
        );
        expect(find.text('Keep this draft'), findsOneWidget);
        await tester.tap(find.text('Background tasks · 2 observed'));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(
          tester.getBottomLeft(find.byType(InputBar)).dy,
          lessThanOrEqualTo(340),
        );
        expect(find.text('Keep this draft'), findsOneWidget);
        await send(empty: true);
        expect(find.byType(BackgroundProgressPanel), findsNothing);
        expect(find.text('Keep this draft'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        h.vm.dispose();
        h.sync.dispose();
        h.conn.dispose();
        voice.dispose();
        attach.dispose();
        actions.dispose();
        await tester.runAsync(() async {
          await Hive.close();
          await directory.delete(recursive: true);
        });
        await tester.binding.setSurfaceSize(null);
      }
    },
  );
}
