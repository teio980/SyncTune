import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// A conservative streaming fingerprint. Only Vorbis comment field order and
/// ASCII field-name case are normalized. All other bytes remain significant.
/// Unsupported, malformed, or ambiguous input returns null and uses raw SHA-256.
final class FlacComparisonHasher {
  FlacComparisonHasher() {
    _sink = sha256.startChunkedConversion(_result);
  }

  final _DigestResult _result = _DigestResult();
  late final ByteConversionSink _sink;
  final List<int> _header = <int>[];
  BytesBuilder? _comment;
  int _remaining = 0;
  int _blocks = 0;
  bool _marker = false;
  bool _audio = false;
  bool _last = false;
  bool _invalid = false;
  bool _sawComment = false;
  int _audioBytes = 0;

  void add(List<int> bytes) {
    if (_invalid) return;
    var offset = 0;
    while (offset < bytes.length && !_invalid) {
      if (_audio) {
        _sink.add(bytes.sublist(offset));
        _audioBytes += bytes.length - offset;
        return;
      }
      if (_remaining > 0) {
        final count = (bytes.length - offset < _remaining)
            ? bytes.length - offset
            : _remaining;
        final part = bytes.sublist(offset, offset + count);
        if (_comment != null) {
          _comment!.add(part);
        } else {
          _sink.add(part);
        }
        _remaining -= count;
        offset += count;
        if (_remaining == 0) _finishBlock();
        continue;
      }
      final count = (4 - _header.length < bytes.length - offset)
          ? 4 - _header.length
          : bytes.length - offset;
      _header.addAll(bytes.sublist(offset, offset + count));
      offset += count;
      if (_header.length != 4) continue;
      final header = List<int>.of(_header);
      _header.clear();
      if (!_marker) {
        if (header[0] != 0x66 ||
            header[1] != 0x4c ||
            header[2] != 0x61 ||
            header[3] != 0x43) {
          _invalid = true;
          return;
        }
        _marker = true;
        _sink.add(header);
        continue;
      }
      final type = header[0] & 0x7f;
      _last = (header[0] & 0x80) != 0;
      final length = (header[1] << 16) | (header[2] << 8) | header[3];
      if ((_blocks == 0 && (type != 0 || length != 34)) ||
          (_blocks > 0 && type == 0) ||
          type == 127 ||
          (type == 4 && (_sawComment || length > 8 * 1024 * 1024))) {
        _invalid = true;
        return;
      }
      _blocks++;
      _sink.add(header);
      _remaining = length;
      if (type == 4) {
        _sawComment = true;
        _comment = BytesBuilder(copy: false);
      }
      if (_remaining == 0) _finishBlock();
    }
  }

  void _finishBlock() {
    final comment = _comment;
    if (comment != null) {
      _comment = null;
      try {
        _sink.add(_normalizedComment(comment.takeBytes()));
      } on FormatException {
        _invalid = true;
        return;
      } on RangeError {
        _invalid = true;
        return;
      }
    }
    if (_last) _audio = true;
  }

  String? close() {
    if (_invalid ||
        !_marker ||
        !_audio ||
        _remaining != 0 ||
        _audioBytes == 0) {
      return null;
    }
    _sink.close();
    return _result.value?.toString();
  }
}

List<int> _normalizedComment(Uint8List bytes) {
  var pos = 0;
  int number() {
    if (pos + 4 > bytes.length) throw const FormatException('Short comment');
    final n = ByteData.sublistView(
      bytes,
      pos,
      pos + 4,
    ).getUint32(0, Endian.little);
    pos += 4;
    return n;
  }

  List<int> field() {
    final n = number();
    if (n > bytes.length - pos) throw const FormatException('Short field');
    final result = bytes.sublist(pos, pos + n);
    pos += n;
    return result;
  }

  final vendor = field();
  utf8.decode(vendor);
  final count = number();
  if (count > (bytes.length - pos) ~/ 4) {
    throw const FormatException('Invalid count');
  }
  final fields = <(List<int>, int)>[];
  for (var i = 0; i < count; i++) {
    final value = field();
    utf8.decode(value);
    final equal = value.indexOf(0x3d);
    if (equal <= 0) throw const FormatException('Invalid name');
    for (var j = 0; j < equal; j++) {
      final c = value[j];
      if (c < 0x20 || c > 0x7d || c == 0x3d) {
        throw const FormatException('Invalid name');
      }
      if (c >= 0x61 && c <= 0x7a) value[j] = c - 32;
    }
    fields.add((value, i));
  }
  if (pos != bytes.length) throw const FormatException('Extra comment bytes');
  fields.sort((a, b) {
    final ae = a.$1.indexOf(0x3d), be = b.$1.indexOf(0x3d);
    for (var i = 0; i < ae && i < be; i++) {
      final order = a.$1[i].compareTo(b.$1[i]);
      if (order != 0) return order;
    }
    final order = ae.compareTo(be);
    return order != 0 ? order : a.$2.compareTo(b.$2);
  });
  final out = BytesBuilder(copy: false);
  void putNumber(int n) {
    final b = ByteData(4)..setUint32(0, n, Endian.little);
    out.add(b.buffer.asUint8List());
  }

  void putField(List<int> v) {
    putNumber(v.length);
    out.add(v);
  }

  putField(vendor);
  putNumber(fields.length);
  for (final item in fields) {
    putField(item.$1);
  }
  return out.takeBytes();
}

final class _DigestResult implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
