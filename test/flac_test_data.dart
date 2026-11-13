import 'dart:convert';
import 'dart:typed_data';

List<int> testFlac(
  List<String> fields, {
  List<int> audio = const [1, 2, 3],
  List<int> picture = const [4, 5],
  String vendor = 'test',
}) {
  final comments = BytesBuilder();
  void number(int n) => comments.add(
    (ByteData(4)..setUint32(0, n, Endian.little)).buffer.asUint8List(),
  );
  void text(String text) {
    final bytes = utf8.encode(text);
    number(bytes.length);
    comments.add(bytes);
  }

  text(vendor);
  number(fields.length);
  for (final field in fields) {
    text(field);
  }
  final comment = comments.takeBytes();
  List<int> block(int type, List<int> body) => [
    type,
    body.length >> 16 & 255,
    body.length >> 8 & 255,
    body.length & 255,
    ...body,
  ];
  return [
    ...utf8.encode('fLaC'),
    ...block(0, List.filled(34, 0)),
    ...block(4, comment),
    ...block(0x86, picture),
    ...audio,
  ];
}
