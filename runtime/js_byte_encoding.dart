part of 'js_core.dart';

typedef JDecodedBytes = ({int read, List<int> bytes, bool invalid});

String jBytesString(dynamic input) {
  if (input is! String)
    throw JThrown(JError('TypeError', 'A string is required'));
  return input;
}

dynamic jByteOptions(dynamic input) {
  if (identical(input, jUndefined)) return JObject.root();
  if (!jIsObject(input))
    throw JThrown(JError('TypeError', 'Options must be an object'));
  return input;
}

bool jBase64Url(dynamic options) {
  final alphabet = jGet(options, 'alphabet');
  if (identical(alphabet, jUndefined) || alphabet == 'base64') return false;
  if (alphabet == 'base64url') return true;
  throw JThrown(JError('TypeError', 'Invalid base64 alphabet'));
}

String jBase64Mode(dynamic options) {
  final mode = jGet(options, 'lastChunkHandling');
  if (identical(mode, jUndefined)) return 'loose';
  if (mode is String &&
      ['loose', 'strict', 'stop-before-partial'].contains(mode))
    return mode;
  throw JThrown(JError('TypeError', 'Invalid lastChunkHandling'));
}

JDecodedBytes jDecodeHex(String input, int capacity) {
  final bytes = <int>[];
  var read = 0;
  if (input.length.isOdd) return (read: 0, bytes: bytes, invalid: true);
  final valid = RegExp(r'^[0-9a-fA-F]{2}$');
  while (read < input.length && bytes.length < capacity) {
    final pair = input.substring(read, read + 2);
    if (!valid.hasMatch(pair)) return (read: read, bytes: bytes, invalid: true);
    bytes.add(int.parse(pair, radix: 16));
    read += 2;
  }
  return (read: read, bytes: bytes, invalid: false);
}

JDecodedBytes jDecodeBase64(String input, bool url, String mode, int capacity) {
  const common =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  final symbols = common + (url ? '-_' : '+/');
  final bytes = <int>[];
  final chunk = <int>[];
  var read = 0, cursor = 0;
  JDecodedBytes result(bool invalid) =>
      (read: read, bytes: bytes, invalid: invalid);

  void skipSpace() {
    while (cursor < input.length && ' \t\n\r\f'.contains(input[cursor])) {
      cursor++;
    }
  }

  void writeChunk() {
    bytes.add((chunk[0] << 2) | (chunk[1] >> 4));
    if (chunk.length > 2) bytes.add(((chunk[1] & 15) << 4) | (chunk[2] >> 2));
    if (chunk.length > 3) bytes.add(((chunk[2] & 3) << 6) | chunk[3]);
  }

  if (capacity == 0) return result(false);
  while (true) {
    skipSpace();
    if (cursor == input.length) {
      if (chunk.isNotEmpty) {
        if (mode == 'stop-before-partial') return result(false);
        if (mode == 'strict' || chunk.length == 1) return result(true);
        writeChunk();
      }
      read = cursor;
      return result(false);
    }

    final character = input[cursor++];
    if (character == '=') {
      if (chunk.length < 2) return result(true);
      skipSpace();
      if (chunk.length == 2) {
        if (cursor == input.length)
          return result(mode != 'stop-before-partial');
        if (input[cursor++] != '=') return result(true);
        skipSpace();
      }
      if (cursor != input.length) return result(true);
      if (mode == 'strict' && (chunk.last & (chunk.length == 2 ? 15 : 3)) != 0)
        return result(true);
      writeChunk();
      read = cursor;
      return result(false);
    }

    final symbol = symbols.indexOf(character);
    if (symbol < 0) return result(true);
    final remaining = capacity - bytes.length;
    if (remaining <= 2 && chunk.length == remaining + 1) return result(false);
    chunk.add(symbol);
    if (chunk.length == 4) {
      writeChunk();
      chunk.clear();
      read = cursor;
      if (bytes.length == capacity) return result(false);
    }
  }
}

void jInstallByteEncoding(JFunction constructor, JObject prototype) {
  JTypedArray receiver(dynamic value) {
    if (value is! JTypedArray || value.kind != 'Uint8Array') {
      throw JThrown(JError('TypeError', 'Uint8Array receiver required'));
    }
    return value;
  }

  for (final base64 in [true, false]) {
    final suffix = base64 ? 'Base64' : 'Hex';
    final from = 'from$suffix', set = 'setFrom$suffix', to = 'to$suffix';
    JDecodedBytes decode(
      String source,
      List<dynamic> args,
      JTypedArray? target,
    ) {
      final options = base64 ? jByteOptions(jArg(args, 1)) : null;
      final url = base64 && jBase64Url(options);
      final mode = base64 ? jBase64Mode(options) : 'loose';
      target?.check();
      final capacity = target?.length ?? 9007199254740991;
      return base64
          ? jDecodeBase64(source, url, mode, capacity)
          : jDecodeHex(source, capacity);
    }

    void check(JDecodedBytes decoded) {
      if (decoded.invalid)
        throw JThrown(JError('SyntaxError', 'Invalid $suffix input'));
    }

    constructor.properties[from] = jNamedFunction(
      jBuiltin((args) {
        final decoded = decode(jBytesString(jArg(args, 0)), args, null);
        check(decoded);
        final result = jTypedCreate('Uint8Array', decoded.bytes.length);
        result.buffer.bytes.setRange(0, result.length, decoded.bytes);
        return result;
      }),
      from,
      1,
    );
    prototype.properties[set] = jNamedFunction(
      JFunction((args, value) {
        final array = receiver(value);
        final decoded = decode(jBytesString(jArg(args, 0)), args, array);
        array.buffer.bytes.setRange(
          array.offset,
          array.offset + decoded.bytes.length,
          decoded.bytes,
        );
        check(decoded);
        return JObject({
          'read': decoded.read.toDouble(),
          'written': decoded.bytes.length.toDouble(),
        });
      }, constructible: false),
      set,
      1,
    );
    prototype.properties[to] = jNamedFunction(
      JFunction((args, value) {
        final array = receiver(value);
        final options = base64 ? jByteOptions(jArg(args, 0)) : null;
        final url = base64 && jBase64Url(options);
        final omitPadding = base64 && jTruthy(jGet(options, 'omitPadding'));
        array.check();
        final bytes = Uint8List.sublistView(
          array.buffer.bytes,
          array.offset,
          array.offset + array.length,
        );
        if (!base64)
          return bytes
              .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
              .join();
        final encoded = (url ? base64Url : const Base64Codec()).encode(bytes);
        return omitPadding ? encoded.replaceFirst(RegExp(r'=+$'), '') : encoded;
      }, constructible: false),
      to,
      0,
    );
  }
}
