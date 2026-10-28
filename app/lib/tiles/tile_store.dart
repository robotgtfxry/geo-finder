// Trwały magazyn kafelków mapy na urządzeniu. Na webie go nie ma
// (przeglądarka sama cache'uje odpowiedzi serwera).
export 'tile_store_stub.dart' if (dart.library.io) 'tile_store_io.dart';
