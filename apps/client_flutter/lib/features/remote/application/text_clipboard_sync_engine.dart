import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cross_desktop_remote/core/clipboard/clipboard_platform_adapter.dart';
import 'package:cross_desktop_remote/core/clipboard/clipboard_sync_mode.dart';

const int clipboardWireVersion = 1;
const int clipboardChunkBytes = 9 * 1024;
final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

class ClipboardOffer {
  const ClipboardOffer({
    required this.clipboardId,
    required this.revision,
    required this.hash,
    required this.size,
  });

  factory ClipboardOffer.fromMessage(Map<String, dynamic> message) {
    final clipboardId = message['clipboardId'];
    final revision = message['revision'];
    final hash = message['hash'];
    final size = message['size'];
    if (clipboardId is! String ||
        clipboardId.isEmpty ||
        clipboardId.length > 128 ||
        revision is! num ||
        revision < 0 ||
        revision != revision.toInt() ||
        hash is! String ||
        !_sha256Pattern.hasMatch(hash) ||
        size is! num ||
        size < 0 ||
        size != size.toInt() ||
        size > maxTextClipboardBytes) {
      throw const FormatException('Invalid clipboard offer');
    }
    return ClipboardOffer(
      clipboardId: clipboardId,
      revision: revision.toInt(),
      hash: hash,
      size: size.toInt(),
    );
  }

  final String clipboardId;
  final int revision;
  final String hash;
  final int size;

  Map<String, dynamic> toMessage() => {
    'type': 'offer',
    'version': clipboardWireVersion,
    'clipboardId': clipboardId,
    'revision': revision,
    'hash': hash,
    'size': size,
    'mimeType': 'text/plain;charset=utf-8',
  };
}

class CompletedClipboardText {
  const CompletedClipboardText({required this.offer, required this.text});

  final ClipboardOffer offer;
  final String text;
}

class _OutboundClipboardText {
  const _OutboundClipboardText({required this.offer, required this.bytes});

  final ClipboardOffer offer;
  final Uint8List bytes;
}

class _InboundClipboardText {
  _InboundClipboardText(this.offer);

  final ClipboardOffer offer;
  final BytesBuilder bytes = BytesBuilder(copy: false);
  int nextOffset = 0;
}

/// Session-scoped clipboard protocol state.
///
/// The engine owns revision/hash validation and loop suppression. Native
/// clipboard I/O and WebRTC DataChannel I/O stay outside, so the safety rules
/// remain independently testable.
class TextClipboardSyncEngine {
  TextClipboardSyncEngine({
    required this.localIsController,
    ClipboardSyncMode initialMode = ClipboardSyncMode.bidirectional,
  }) : _mode = initialMode;

  final bool localIsController;
  ClipboardSyncMode _mode;
  int _localRevision = 0;
  int _lastNativeRevision = -1;
  int _lastRemoteRevision = -1;
  String? _expectedEchoHash;
  DateTime? _expectedEchoExpiresAt;
  ClipboardOffer? _pendingOffer;
  _OutboundClipboardText? _outbound;
  _InboundClipboardText? _inbound;

  ClipboardSyncMode get mode => _mode;

  void setMode(ClipboardSyncMode value) {
    _mode = value;
    if (!_mode.allowsInbound(localIsController: localIsController)) {
      _pendingOffer = null;
      _inbound = null;
    }
    if (!_mode.allowsOutbound(localIsController: localIsController)) {
      _outbound = null;
    }
  }

  /// Records current OS state without publishing it. This prevents connection
  /// startup from exposing clipboard history copied before the session.
  void observeBaseline(ClipboardSnapshot snapshot) {
    _lastNativeRevision = snapshot.revision;
  }

  ClipboardOffer? observeLocalChange(ClipboardSnapshot snapshot) {
    if (snapshot.revision == _lastNativeRevision) return null;
    _lastNativeRevision = snapshot.revision;
    if (!snapshot.hasText || snapshot.tooLarge || snapshot.text == null) {
      return null;
    }
    final text = snapshot.text!;
    final bytes = Uint8List.fromList(utf8.encode(text));
    if (bytes.length > maxTextClipboardBytes) return null;
    final hash = hashBytes(bytes);
    if (_expectedEchoHash == hash &&
        DateTime.now().isBefore(
          _expectedEchoExpiresAt ?? DateTime.fromMillisecondsSinceEpoch(0),
        )) {
      _expectedEchoHash = null;
      _expectedEchoExpiresAt = null;
      return null;
    }
    _expectedEchoHash = null;
    _expectedEchoExpiresAt = null;
    if (!_mode.allowsOutbound(localIsController: localIsController)) {
      return null;
    }
    _localRevision += 1;
    final offer = ClipboardOffer(
      clipboardId: '${DateTime.now().microsecondsSinceEpoch}-$_localRevision',
      revision: _localRevision,
      hash: hash,
      size: bytes.length,
    );
    _outbound = _OutboundClipboardText(offer: offer, bytes: bytes);
    return offer;
  }

  Map<String, dynamic>? acceptOffer(ClipboardOffer offer) {
    if (!_mode.allowsInbound(localIsController: localIsController) ||
        offer.revision <= _lastRemoteRevision ||
        offer.size > maxTextClipboardBytes) {
      return null;
    }
    _pendingOffer = offer;
    _inbound = _InboundClipboardText(offer);
    return {
      'type': 'request',
      'version': clipboardWireVersion,
      'clipboardId': offer.clipboardId,
      'revision': offer.revision,
      'hash': offer.hash,
    };
  }

  Iterable<Map<String, dynamic>> chunksForRequest(
    Map<String, dynamic> message,
  ) sync* {
    final outbound = _outbound;
    if (outbound == null ||
        message['clipboardId'] != outbound.offer.clipboardId ||
        (message['revision'] as num?)?.toInt() != outbound.offer.revision ||
        message['hash'] != outbound.offer.hash) {
      return;
    }
    for (
      var offset = 0;
      offset < outbound.bytes.length;
      offset += clipboardChunkBytes
    ) {
      final end = (offset + clipboardChunkBytes).clamp(
        0,
        outbound.bytes.length,
      );
      final chunk = outbound.bytes.sublist(offset, end);
      yield {
        'type': 'data',
        'version': clipboardWireVersion,
        'clipboardId': outbound.offer.clipboardId,
        'revision': outbound.offer.revision,
        'hash': outbound.offer.hash,
        'offset': offset,
        'payload': base64Encode(chunk),
        'complete': end == outbound.bytes.length,
      };
    }
    if (outbound.bytes.isEmpty) {
      yield {
        'type': 'data',
        'version': clipboardWireVersion,
        'clipboardId': outbound.offer.clipboardId,
        'revision': outbound.offer.revision,
        'hash': outbound.offer.hash,
        'offset': 0,
        'payload': '',
        'complete': true,
      };
    }
  }

  CompletedClipboardText? acceptData(Map<String, dynamic> message) {
    final inbound = _inbound;
    final pending = _pendingOffer;
    if (inbound == null ||
        pending == null ||
        message['clipboardId'] != pending.clipboardId ||
        (message['revision'] as num?)?.toInt() != pending.revision ||
        message['hash'] != pending.hash ||
        (message['offset'] as num?)?.toInt() != inbound.nextOffset ||
        message['payload'] is! String) {
      throw const FormatException('Invalid clipboard data sequence');
    }
    final Uint8List chunk;
    try {
      chunk = base64Decode(message['payload'] as String);
    } on FormatException {
      throw const FormatException('Invalid clipboard data encoding');
    }
    if (chunk.isEmpty && (message['complete'] != true || pending.size != 0)) {
      throw const FormatException('Clipboard data made no progress');
    }
    if (inbound.nextOffset + chunk.length > pending.size ||
        inbound.nextOffset + chunk.length > maxTextClipboardBytes) {
      throw const FormatException('Clipboard data exceeds declared size');
    }
    inbound.bytes.add(chunk);
    inbound.nextOffset += chunk.length;
    if (message['complete'] != true) return null;
    final bytes = inbound.bytes.takeBytes();
    _inbound = null;
    _pendingOffer = null;
    if (bytes.length != pending.size || hashBytes(bytes) != pending.hash) {
      throw const FormatException('Clipboard data integrity check failed');
    }
    final text = utf8.decode(bytes, allowMalformed: false);
    _lastRemoteRevision = pending.revision;
    return CompletedClipboardText(offer: pending, text: text);
  }

  void expectNativeEcho(String text) {
    _expectedEchoHash = hashText(text);
    _expectedEchoExpiresAt = DateTime.now().add(const Duration(seconds: 3));
  }

  void resetSession() {
    _localRevision = 0;
    _lastRemoteRevision = -1;
    _pendingOffer = null;
    _outbound = null;
    _inbound = null;
    _expectedEchoHash = null;
    _expectedEchoExpiresAt = null;
  }
}

String hashText(String text) => hashBytes(utf8.encode(text));

String hashBytes(List<int> bytes) => sha256.convert(bytes).toString();
