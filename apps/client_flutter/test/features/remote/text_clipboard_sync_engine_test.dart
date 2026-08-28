import 'dart:convert';

import 'package:cross_desktop_remote/core/clipboard/clipboard_platform_adapter.dart';
import 'package:cross_desktop_remote/core/clipboard/clipboard_sync_mode.dart';
import 'package:cross_desktop_remote/features/remote/application/text_clipboard_sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

ClipboardSnapshot snapshot(int revision, String text) => ClipboardSnapshot(
  revision: revision,
  hasText: true,
  tooLarge: false,
  utf8Bytes: utf8.encode(text).length,
  text: text,
);

void main() {
  test('direction policies are explicit for controller and host', () {
    expect(
      ClipboardSyncMode.controllerToHost.allowsOutbound(
        localIsController: true,
      ),
      isTrue,
    );
    expect(
      ClipboardSyncMode.controllerToHost.allowsInbound(localIsController: true),
      isFalse,
    );
    expect(
      ClipboardSyncMode.controllerToHost.allowsInbound(
        localIsController: false,
      ),
      isTrue,
    );
    expect(
      ClipboardSyncMode.disabled.allowsOutbound(localIsController: false),
      isFalse,
    );
  });

  test('baseline is never offered as clipboard history', () {
    final engine = TextClipboardSyncEngine(localIsController: true);

    engine.observeBaseline(snapshot(7, '连接前的私密文本'));

    expect(engine.observeLocalChange(snapshot(7, '连接前的私密文本')), isNull);
  });

  test('explicit paste may publish the baseline with user intent', () {
    final engine = TextClipboardSyncEngine(localIsController: true);
    final baseline = snapshot(7, '准备粘贴的文本');
    engine.observeBaseline(baseline);

    final offer = engine.prepareExplicitOutbound(baseline);

    expect(offer, isNotNull);
    expect(offer?.hash, hashText('准备粘贴的文本'));
    expect(engine.outboundOffer, same(offer));
  });

  test('offer request chunks round trip and validates sha256', () {
    final sender = TextClipboardSyncEngine(localIsController: true);
    final receiver = TextClipboardSyncEngine(localIsController: false);
    sender.observeBaseline(snapshot(1, 'old'));
    receiver.observeBaseline(snapshot(2, 'remote-old'));
    final text = '中文剪贴板-${'x' * (clipboardChunkBytes * 2)}';

    final offer = sender.observeLocalChange(snapshot(2, text));
    expect(offer, isNotNull);
    final request = receiver.acceptOffer(offer!);
    expect(request, isNotNull);
    CompletedClipboardText? completed;
    final chunks = sender.chunksForRequest(request!).toList();
    expect(chunks.length, greaterThan(2));
    for (final chunk in chunks) {
      completed = receiver.acceptData(chunk) ?? completed;
    }

    expect(completed?.text, text);
    expect(completed?.offer.hash, hashText(text));
    expect(receiver.acceptOffer(offer), isNull, reason: '已应用 revision 不应重放');
  });

  test('native echo is suppressed once without blocking a later user copy', () {
    final engine = TextClipboardSyncEngine(localIsController: false);
    engine.observeBaseline(snapshot(1, 'old'));
    engine.expectNativeEcho('remote');

    expect(engine.observeLocalChange(snapshot(2, 'remote')), isNull);
    expect(engine.observeLocalChange(snapshot(3, 'remote')), isNotNull);
  });

  test('disabled and wrong-direction modes do not create offers', () {
    final engine = TextClipboardSyncEngine(
      localIsController: true,
      initialMode: ClipboardSyncMode.hostToController,
    );
    engine.observeBaseline(snapshot(1, 'old'));

    expect(engine.observeLocalChange(snapshot(2, 'new')), isNull);
    engine.setMode(ClipboardSyncMode.disabled);
    expect(engine.observeLocalChange(snapshot(3, 'newer')), isNull);
  });

  test('out-of-order data is rejected', () {
    final sender = TextClipboardSyncEngine(localIsController: true);
    final receiver = TextClipboardSyncEngine(localIsController: false);
    sender.observeBaseline(snapshot(1, 'old'));
    receiver.observeBaseline(snapshot(1, 'old'));
    final offer = sender.observeLocalChange(
      snapshot(2, 'x' * (clipboardChunkBytes + 1)),
    )!;
    final request = receiver.acceptOffer(offer)!;
    final chunks = sender.chunksForRequest(request).toList();

    expect(
      () => receiver.acceptData(chunks.last),
      throwsA(isA<FormatException>()),
    );
  });

  test('tampered payload fails the declared sha256 digest', () {
    final sender = TextClipboardSyncEngine(localIsController: true);
    final receiver = TextClipboardSyncEngine(localIsController: false);
    sender.observeBaseline(snapshot(1, 'old'));
    receiver.observeBaseline(snapshot(1, 'old'));
    final offer = sender.observeLocalChange(snapshot(2, 'protected text'))!;
    final request = receiver.acceptOffer(offer)!;
    final chunk = sender.chunksForRequest(request).single;
    final tampered = {
      ...chunk,
      'payload': base64Encode(utf8.encode('tampered value')),
    };

    expect(
      () => receiver.acceptData(tampered),
      throwsA(isA<FormatException>()),
    );
  });

  test('applied acknowledgement releases an explicit paste gate', () async {
    final gate = ClipboardApplyGate();
    final offer = ClipboardOffer(
      clipboardId: 'clipboard-1',
      revision: 1,
      hash: hashText('ready'),
      size: 5,
    );

    final waiting = gate.waitFor(offer);
    expect(gate.accept(clipboardAppliedMessage(offer)), isTrue);

    expect(await waiting, isTrue);
    expect(await gate.waitFor(offer), isTrue);
  });

  test('applied gate times out for legacy peers', () async {
    final gate = ClipboardApplyGate();
    final offer = ClipboardOffer(
      clipboardId: 'clipboard-legacy',
      revision: 1,
      hash: hashText('legacy'),
      size: 6,
    );

    expect(
      await gate.waitFor(offer, timeout: const Duration(milliseconds: 1)),
      isFalse,
    );
  });
}
