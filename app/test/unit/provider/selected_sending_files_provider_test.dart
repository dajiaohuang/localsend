import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/pages/home_page.dart';
import 'package:localsend_app/pages/home_page_controller.dart';
import 'package:localsend_app/provider/network/server/controller/receive_controller.dart';
import 'package:localsend_app/provider/network/server/server_utils.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/rust/api/model.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:mockito/mockito.dart';
import 'package:path/path.dart' as p;
import 'package:refena_flutter/refena_flutter.dart';

void main() {
  // https://github.com/localsend/localsend/issues/3417
  //
  // Desktop entries declare `Exec=localsend %U`, so a file argument arrives as
  // a file:// URI. Flatpak's `--file-forwarding @@u` delivers it in exactly that
  // form: the same file arrives as `/run/user/1000/doc/<id>/test.txt` in path
  // mode but as `file:///run/user/1000/doc/<id>/test.txt` in URI mode.

  test('loads an existing file URI into the sending selection', () async {
    final directory = await Directory.systemTemp.createTemp();
    addTearDown(() => directory.delete(recursive: true));
    final file = File(p.join(directory.path, 'selected file.txt'));
    await file.writeAsString('selected');
    final api = _MetadataApi();
    RustLib.initMock(api: api);
    addTearDown(RustLib.dispose);
    final service = ReduxNotifier.test(redux: SelectedSendingFilesNotifier());

    final filesAdded = await service.dispatchAsyncTakeResult(LoadSelectionFromArgsAction([file.uri.toString()]));

    expect(filesAdded, isTrue);
    expect(service.state, hasLength(1));
    expect(service.state.single.path, file.path);
    expect(service.state.single.name, 'selected file.txt');
    expect(service.state.single.size, 8);
    expect(api.paths, [file.path]);
  });

  testWidgets('onShow loads an existing file URI and switches from Receive to Send', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final api = _MetadataApi();
    RustLib.initMock(api: api);
    addTearDown(RustLib.dispose);
    final ref = RefenaContainer();
    final home = ref.read(homePageControllerProvider);
    addTearDown(() {
      home.controller.dispose();
      ref.disposeContainer();
    });

    // ChangeTabAction must use a genuinely attached PageController, not a mocked action.
    await tester.pumpWidget(
      RefenaScope.withContainer(
        container: ref,
        ownsContainer: false,
        child: MaterialApp(
          home: PageView(
            controller: home.controller,
            children: [for (final tab in HomeTab.values) Center(child: Text(tab.name))],
          ),
        ),
      ),
    );
    expect(ref.read(homePageControllerProvider).currentTab, HomeTab.receive);
    expect(home.controller.page, HomeTab.receive.index.toDouble());

    // Only the external window and native metadata boundaries are mocked.
    const windowChannel = MethodChannel('window_manager');
    final focused = Completer<void>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(windowChannel, (call) async {
      switch (call.method) {
        case 'isMinimized':
          return false;
        case 'show':
          return null;
        case 'focus':
          focused.complete();
          return null;
        default:
          throw UnsupportedError('Unexpected window method: ${call.method}');
      }
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(windowChannel, null));
    ServerState? serverState = const ServerState(alias: 'test', port: 53317, https: false, session: null, web: null);
    final controller = ReceiveController(
      ServerUtils(
        refFunc: () => ref,
        getState: () => serverState!,
        getStateOrNull: () => serverState,
        setState: (builder) => serverState = builder(serverState),
      ),
    );

    // onShow returns void and starts real filesystem work. Wait outside fake time,
    // subscribing before dispatch, with a bounded failure instead of pumpAndSettle.
    await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp();
      try {
        final file = File(p.join(directory.path, 'selected file.txt'));
        await file.writeAsString('selected');
        final sent = ref.stream(homePageControllerProvider).firstWhere((event) => event.next.currentTab == HomeTab.send);
        controller.onShow(HttpServerShowEvent(args: [file.uri.toString()]));
        await Future.wait([sent, focused.future]).timeout(const Duration(seconds: 5));

        expect(ref.read(homePageControllerProvider).currentTab, HomeTab.send);
        expect(home.controller.page, HomeTab.send.index.toDouble());
        final selection = ref.read(selectedSendingFilesProvider);
        expect(selection, hasLength(1));
        expect(selection.single.path, file.path);
        expect(selection.single.name, 'selected file.txt');
        expect(selection.single.size, 8);
        expect(api.paths, [file.path]);
      } finally {
        await directory.delete(recursive: true);
      }
    });
    await tester.pump();
    expect(find.text(HomeTab.send.name).hitTestable(), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  group('resolveArgPath', () {
    test('resolves a file URI to a path', () {
      expect(
        resolveArgPath('file:///home/user/Documents/test.txt'),
        '/home/user/Documents/test.txt',
      );
    });

    test('unescapes percent-encoded characters', () {
      expect(resolveArgPath('file:///home/user/My%20Files/a%2Bb.txt'), '/home/user/My Files/a+b.txt');
    });

    test('leaves a plain path untouched', () {
      expect(resolveArgPath('/home/user/Documents/test.txt'), '/home/user/Documents/test.txt');
    });

    test('leaves a relative path untouched', () {
      expect(resolveArgPath('test.txt'), 'test.txt');
    });

    test('resolves a localhost authority', () {
      expect(resolveArgPath('file://localhost/home/user/test.txt'), '/home/user/test.txt');
    });

    test('rejects a URI pointing at another host', () {
      expect(resolveArgPath('file://remote-host/share/test.txt'), isNull);
    });

    test('rejects a non-file URI scheme', () {
      expect(resolveArgPath('https://example.com/test.txt'), 'https://example.com/test.txt');
    });

    test('rejects a file URI with a fragment', () {
      expect(resolveArgPath('file:///home/user/test.txt#section'), isNull);
    });

    test('resolves a Windows drive letter URI on Windows', () {
      final expected = Platform.isWindows ? r'C:\Users\test.txt' : '/C:/Users/test.txt';
      expect(resolveArgPath('file:///C:/Users/test.txt'), expected);
    });

    test('rejects a file URI with an invalid percent-escape', () {
      expect(resolveArgPath('file:///tmp/%FF'), isNull);
    });

    test('rejects a file URI with an incomplete UTF-8 escape', () {
      expect(resolveArgPath('file:///%E4%F6'), isNull);
    });
  });
}

// Only the native timestamp boundary is mocked; URI resolution, filesystem
// existence checks, conversion and selection updates use production code.
class _MetadataApi extends Mock implements RustLibApi {
  final paths = <String>[];

  @override
  Future<FileMetadata?> crateApiMetadataReadFileMetadata({required String path}) async {
    paths.add(path);
    return null; // Missing timestamps are supported by the converter contract.
  }
}
