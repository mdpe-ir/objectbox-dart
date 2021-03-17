import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../common.dart';
import '../../modelinfo/entity_definition.dart';
import '../store.dart';
import 'bindings.dart';

// ignore_for_file: public_member_api_docs

@pragma('vm:prefer-inline')
void checkObx(int code) {
  if (code != OBX_SUCCESS) {
    throw latestNativeError(codeIfMissing: code);
  }
}

@pragma('vm:prefer-inline')
bool checkObxSuccess(int code) {
  if (code == OBX_NO_SUCCESS) return false;
  checkObx(code);
  return true;
}

@pragma('vm:prefer-inline')
Pointer<T> checkObxPtr<T extends NativeType>(Pointer<T>? ptr,
    [String? dartMsg]) {
  if (ptr == null || ptr.address == 0) {
    throw latestNativeError(dartMsg: dartMsg);
  }
  return ptr;
}

ObjectBoxException latestNativeError(
    {String? dartMsg, int codeIfMissing = OBX_ERROR_UNKNOWN}) {
  final code = C.last_error_code();
  final text = dartStringFromC(C.last_error_message());

  if (code == 0 && text.isEmpty) {
    return ObjectBoxException(
        dartMsg: dartMsg,
        nativeCode: codeIfMissing,
        nativeMsg: 'unknown native error');
  }

  return ObjectBoxException(
      dartMsg: dartMsg, nativeCode: code, nativeMsg: text);
}

@pragma('vm:prefer-inline')
String dartStringFromC(Pointer<Int8> charPtr) =>
    charPtr.address == 0 ? '' : charPtr.cast<Utf8>().toDartString();

class CursorHelper<T> {
  final EntityDefinition<T> _entity;
  final Store _store;
  final Pointer<OBX_cursor> ptr;

  final bool _isWrite;
  late final Pointer<Pointer<Void>> dataPtrPtr;

  late final Pointer<IntPtr> sizePtr;

  bool _closed = false;

  CursorHelper(this._store, Pointer<OBX_txn> txn, this._entity,
      {required bool isWrite})
      : ptr = checkObxPtr(
            C.cursor(txn, _entity.model.id.id), 'failed to create cursor'),
        _isWrite = isWrite {
    if (!_isWrite) {
      dataPtrPtr = malloc();
      sizePtr = malloc();
    }
  }

  Uint8List get readData =>
      dataPtrPtr.value.cast<Uint8>().asTypedList(sizePtr.value);

  EntityDefinition<T> get entity => _entity;

  void close() {
    if (_closed) return;
    _closed = true;
    if (!_isWrite) {
      malloc.free(dataPtrPtr);
      malloc.free(sizePtr);
    }
    checkObx(C.cursor_close(ptr));
  }

  @pragma('vm:prefer-inline')
  T? get(int id) {
    final code = C.cursor_get(ptr, id, dataPtrPtr, sizePtr);
    if (code == OBX_NOT_FOUND) return null;
    checkObx(code);
    return _entity.objectFromFB(_store, readData);
  }
}

T withNativeBytes<T>(
    Uint8List data, T Function(Pointer<Void> ptr, int size) fn) {
  final size = data.length;
  assert(size == data.lengthInBytes);
  final ptr = malloc<Uint8>(size);
  try {
    ptr.asTypedList(size).setAll(0, data); // copies `data` to `ptr`
    return fn(ptr.cast<Void>(), size);
  } finally {
    malloc.free(ptr);
  }
}

/// Execute the given function, managing the resources consistently
R executeWithIdArray<R>(List<int> items, R Function(Pointer<OBX_id_array>) fn) {
  // allocate a temporary structure
  final ptr = malloc<OBX_id_array>();

  // fill it with data
  final array = ptr.ref;
  array.count = items.length;
  array.ids = malloc<Uint64>(items.length);
  for (var i = 0; i < items.length; ++i) {
    array.ids[i] = items[i];
  }

  // call the function with the structure and free afterwards
  try {
    return fn(ptr);
  } finally {
    malloc.free(array.ids);
    malloc.free(ptr);
  }
}

extension NativeStringArrayAccess on Pointer<OBX_string_array> {
  List<String> toDartStrings() {
    final cArray = ref;
    final items = cArray.items.cast<Pointer<Utf8>>();
    return List<String>.generate(cArray.count, (i) => items[i].toDartString());
  }
}