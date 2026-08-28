import 'dart:convert';
import 'dart:typed_data';

import 'package:cross_desktop_remote/features/remote/application/explicit_file_transfer_models.dart';

const int explicitFileTransferWireVersion = 1;
const int explicitFileTransferWireMessageBytes = 16 * 1024;
const int explicitFileTransferLogicalBlockBytes = 256 * 1024;
const int explicitFileTransferMaxInFlightFragments = 8;
const int explicitFileTransferBinaryHeaderBytes = 36;
const int explicitFileTransferPayloadBytes =
    explicitFileTransferWireMessageBytes -
    explicitFileTransferBinaryHeaderBytes;
const int explicitFileTransferMaxEntries = 10000;
const int explicitFileTransferMaxPathBytes = 4096;
const int explicitFileTransferMaxPathDepth = 64;

const _frameMagic = <int>[0x43, 0x44, 0x52, 0x46]; // CDRF

class ExplicitFileTransferFrame {
  const ExplicitFileTransferFrame({
    required this.transferId,
    required this.entryIndex,
    required this.offset,
    required this.payload,
    required this.endOfEntry,
  });

  final String transferId;
  final int entryIndex;
  final int offset;
  final Uint8List payload;
  final bool endOfEntry;
}

Uint8List encodeExplicitFileTransferFrame(ExplicitFileTransferFrame frame) {
  if (frame.payload.length > explicitFileTransferPayloadBytes ||
      frame.offset < 0 ||
      frame.entryIndex < 0) {
    throw const FormatException('文件分片超出协议限制');
  }
  final id = _decodeTransferId(frame.transferId);
  final output = Uint8List(
    explicitFileTransferBinaryHeaderBytes + frame.payload.length,
  );
  output.setRange(0, 4, _frameMagic);
  output[4] = explicitFileTransferWireVersion;
  output[5] = frame.endOfEntry ? 1 : 0;
  output.setRange(8, 24, id);
  final data = ByteData.sublistView(output);
  data.setUint32(24, frame.entryIndex, Endian.little);
  data.setUint64(28, frame.offset, Endian.little);
  output.setRange(
    explicitFileTransferBinaryHeaderBytes,
    output.length,
    frame.payload,
  );
  return output;
}

ExplicitFileTransferFrame decodeExplicitFileTransferFrame(Uint8List bytes) {
  if (bytes.length < explicitFileTransferBinaryHeaderBytes ||
      bytes.length > explicitFileTransferWireMessageBytes ||
      !_matchesMagic(bytes) ||
      bytes[4] != explicitFileTransferWireVersion) {
    throw const FormatException('文件分片帧无效');
  }
  final data = ByteData.sublistView(bytes);
  return ExplicitFileTransferFrame(
    transferId: _encodeTransferId(bytes.sublist(8, 24)),
    entryIndex: data.getUint32(24, Endian.little),
    offset: data.getUint64(28, Endian.little),
    payload: Uint8List.sublistView(
      bytes,
      explicitFileTransferBinaryHeaderBytes,
    ),
    endOfEntry: bytes[5] & 1 == 1,
  );
}

void validateExplicitFileTransferManifest(
  List<ExplicitFileTransferEntry> entries, {
  required int declaredTotalBytes,
}) {
  if (entries.isEmpty || entries.length > explicitFileTransferMaxEntries) {
    throw const FormatException('文件清单项数超出限制');
  }
  final paths = <String>{};
  final kinds = <String, ExplicitFileEntryKind>{};
  var total = 0;
  for (var expectedIndex = 0; expectedIndex < entries.length; expectedIndex++) {
    final entry = entries[expectedIndex];
    if (entry.index != expectedIndex) {
      throw const FormatException('文件清单索引不连续');
    }
    validateExplicitFileTransferRelativePath(entry.relativePath);
    if (!paths.add(entry.relativePath)) {
      throw const FormatException('文件清单包含重复路径');
    }
    if (entry.sizeBytes < 0 ||
        (entry.kind == ExplicitFileEntryKind.directory &&
            (entry.sizeBytes != 0 || entry.sha256Hex.isNotEmpty)) ||
        (entry.kind == ExplicitFileEntryKind.file &&
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(entry.sha256Hex))) {
      throw const FormatException('文件清单元数据无效');
    }
    total += entry.sizeBytes;
    kinds[entry.relativePath] = entry.kind;
  }
  if (total != declaredTotalBytes) {
    throw const FormatException('文件清单总大小不匹配');
  }
  for (final path in paths) {
    final components = path.split('/');
    for (var end = 1; end < components.length; end++) {
      final ancestor = components.take(end).join('/');
      if (kinds[ancestor] == ExplicitFileEntryKind.file) {
        throw const FormatException('文件清单将内容放在文件之下');
      }
    }
  }
}

void validateExplicitFileTransferRelativePath(String raw) {
  final bytes = utf8.encode(raw);
  if (raw.isEmpty || bytes.length > explicitFileTransferMaxPathBytes) {
    throw const FormatException('相对路径为空或过长');
  }
  if (raw.startsWith('/') ||
      raw.startsWith(r'\') ||
      RegExp(r'^[A-Za-z]:').hasMatch(raw)) {
    throw const FormatException('不允许绝对路径');
  }
  final normalized = raw.replaceAll(r'\', '/');
  final components = normalized.split('/');
  if (components.length > explicitFileTransferMaxPathDepth) {
    throw const FormatException('相对路径层级过深');
  }
  for (final component in components) {
    if (component.isEmpty ||
        component == '.' ||
        component == '..' ||
        utf8.encode(component).length > 255 ||
        component.contains(':') ||
        component.endsWith(' ') ||
        component.endsWith('.') ||
        component.runes.any((value) => value < 0x20 || value == 0x7f)) {
      throw const FormatException('相对路径包含非法组件');
    }
    final stem = component.split('.').first.toUpperCase();
    if ({'CON', 'PRN', 'AUX', 'NUL'}.contains(stem) ||
        RegExp(r'^(COM|LPT)[1-9]$').hasMatch(stem)) {
      throw const FormatException('相对路径包含 Windows 保留名');
    }
  }
}

String encodeResumeBitmap(Set<int> completedBlocks, int blockCount) {
  final bytes = Uint8List((blockCount + 7) ~/ 8);
  for (final block in completedBlocks) {
    if (block < 0 || block >= blockCount) continue;
    bytes[block ~/ 8] |= 1 << (block % 8);
  }
  return base64Encode(bytes);
}

Set<int> decodeResumeBitmap(String encoded, int blockCount) {
  final bytes = base64Decode(encoded);
  if (bytes.length != (blockCount + 7) ~/ 8) {
    throw const FormatException('恢复位图大小不匹配');
  }
  return {
    for (var block = 0; block < blockCount; block++)
      if (bytes[block ~/ 8] & (1 << (block % 8)) != 0) block,
  };
}

bool _matchesMagic(Uint8List bytes) {
  for (var index = 0; index < _frameMagic.length; index++) {
    if (bytes[index] != _frameMagic[index]) return false;
  }
  return true;
}

Uint8List _decodeTransferId(String value) {
  if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
    throw const FormatException('传输 ID 无效');
  }
  return Uint8List.fromList([
    for (var index = 0; index < value.length; index += 2)
      int.parse(value.substring(index, index + 2), radix: 16),
  ]);
}

String _encodeTransferId(List<int> bytes) =>
    bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
