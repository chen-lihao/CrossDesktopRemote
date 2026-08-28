import 'dart:typed_data';

import 'package:cross_desktop_remote/features/remote/application/explicit_file_transfer_models.dart';
import 'package:cross_desktop_remote/features/remote/application/explicit_file_transfer_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('16 KiB binary frame round-trips without exceeding wire limit', () {
    final payload = Uint8List.fromList(
      List<int>.generate(explicitFileTransferPayloadBytes, (index) => index),
    );
    final encoded = encodeExplicitFileTransferFrame(
      ExplicitFileTransferFrame(
        transferId: '00112233445566778899aabbccddeeff',
        entryIndex: 7,
        offset: 123456,
        payload: payload,
        endOfEntry: true,
      ),
    );

    expect(encoded, hasLength(explicitFileTransferWireMessageBytes));
    final decoded = decodeExplicitFileTransferFrame(encoded);
    expect(decoded.transferId, '00112233445566778899aabbccddeeff');
    expect(decoded.entryIndex, 7);
    expect(decoded.offset, 123456);
    expect(decoded.endOfEntry, isTrue);
    expect(decoded.payload, payload);
  });

  test('resume bitmap preserves completed logical blocks', () {
    final encoded = encodeResumeBitmap({0, 2, 8}, 9);
    expect(decodeResumeBitmap(encoded, 9), {0, 2, 8});
  });

  test('manifest rejects traversal, absolute and reserved names', () {
    for (final path in [
      '../secret.txt',
      '/etc/passwd',
      r'C:\secret.txt',
      'folder/CON.txt',
    ]) {
      expect(
        () => validateExplicitFileTransferRelativePath(path),
        throwsFormatException,
      );
    }
  });

  test('manifest accepts nested unicode and emoji paths', () {
    final entries = [
      const ExplicitFileTransferEntry(
        index: 0,
        relativePath: '资料📁',
        kind: ExplicitFileEntryKind.directory,
        sizeBytes: 0,
        modifiedAtUnixMs: 0,
        sha256Hex: '',
      ),
      const ExplicitFileTransferEntry(
        index: 1,
        relativePath: '资料📁/报告🚀.txt',
        kind: ExplicitFileEntryKind.file,
        sizeBytes: 3,
        modifiedAtUnixMs: 0,
        sha256Hex:
            'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      ),
    ];

    expect(
      () =>
          validateExplicitFileTransferManifest(entries, declaredTotalBytes: 3),
      returnsNormally,
    );
  });
}
