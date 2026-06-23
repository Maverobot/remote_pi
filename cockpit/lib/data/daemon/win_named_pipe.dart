import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Nome do named pipe do supervisor no Windows. Espelha
/// `pi-extension/src/session/ipc.ts`: `\\.\pipe\remote-pi-supervisor-<user>`,
/// com o username sanitizado (`[^A-Za-z0-9_.-]` → `_`).
String supervisorPipeName() {
  final raw = Platform.environment['USERNAME'] ?? 'user';
  final user = raw.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
  return r'\\.\pipe\remote-pi-supervisor-' + (user.isEmpty ? 'user' : user);
}

/// Faz uma transação completa num named pipe do Windows: conecta, escreve
/// [requestLine] (que deve terminar em `\n`), lê uma linha de resposta e fecha.
/// Devolve a linha (sem o `\n`) ou `null` em offline/erro/timeout.
///
/// As chamadas FFI são bloqueantes, então rodam num `Isolate.run` pra não travar
/// a UI. Só passamos Strings (sendable) pro isolate.
Future<String?> winPipeTransact(
  String pipeName,
  String requestLine, {
  Duration timeout = const Duration(seconds: 6),
}) {
  final deadlineMs = timeout.inMilliseconds;
  return Isolate.run(() => _transactSync(pipeName, requestLine, deadlineMs));
}

/// Roda dentro do isolate. Tudo síncrono (Win32 bloqueante).
String? _transactSync(String pipeName, String requestLine, int deadlineMs) {
  final namePtr = pipeName.toNativeUtf16();
  var handle = INVALID_HANDLE_VALUE;
  final sw = Stopwatch()..start();
  try {
    // Abre o pipe; em ERROR_PIPE_BUSY tenta de novo até o deadline (win32 5.x
    // não expõe WaitNamedPipe, então fazemos backoff curto manual).
    while (true) {
      handle = CreateFile(
        namePtr,
        GENERIC_READ | GENERIC_WRITE,
        0,
        nullptr,
        OPEN_EXISTING,
        0,
        0,
      );
      if (handle != INVALID_HANDLE_VALUE) break;
      final err = GetLastError();
      if (err != ERROR_PIPE_BUSY || sw.elapsedMilliseconds >= deadlineMs) {
        return null; // offline / inexistente / sem permissão.
      }
      sleep(const Duration(milliseconds: 50));
    }

    if (!_writeAll(handle, utf8.encode(requestLine))) return null;
    return _readLine(handle, sw, deadlineMs);
  } finally {
    if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle);
    calloc.free(namePtr);
  }
}

bool _writeAll(int handle, List<int> bytes) {
  final len = bytes.length;
  final buf = calloc<Uint8>(len);
  final written = calloc<Uint32>();
  try {
    buf.asTypedList(len).setAll(0, bytes);
    var off = 0;
    while (off < len) {
      final ok = WriteFile(
        handle,
        (buf + off).cast(),
        len - off,
        written,
        nullptr,
      );
      if (ok == 0 || written.value == 0) return false;
      off += written.value;
    }
    return true;
  } finally {
    calloc.free(buf);
    calloc.free(written);
  }
}

/// Lê do pipe acumulando bytes até o primeiro `\n`. Devolve a 1ª linha (sem o
/// `\n`) ou `null` se o pipe fechar antes / estourar o deadline.
String? _readLine(int handle, Stopwatch sw, int deadlineMs) {
  const chunk = 4096;
  final buf = calloc<Uint8>(chunk);
  final read = calloc<Uint32>();
  final acc = <int>[];
  try {
    while (sw.elapsedMilliseconds < deadlineMs) {
      final ok = ReadFile(handle, buf, chunk, read, nullptr);
      if (ok == 0) return null; // pipe quebrado / fim.
      final n = read.value;
      if (n == 0) return null;
      final bytes = buf.asTypedList(n);
      for (var i = 0; i < n; i++) {
        if (bytes[i] == 0x0A) {
          return utf8.decode(acc, allowMalformed: true);
        }
        acc.add(bytes[i]);
      }
    }
    return null;
  } finally {
    calloc.free(buf);
    calloc.free(read);
  }
}
