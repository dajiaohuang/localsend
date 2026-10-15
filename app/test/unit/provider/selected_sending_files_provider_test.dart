import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
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
