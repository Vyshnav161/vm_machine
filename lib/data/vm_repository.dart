import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/domain.dart';
import 'profile_serializer.dart';

/// Persistence for VM profiles (Req 10.1).
abstract class VmRepository {
  Future<List<VmProfile>> loadAll();
  Future<void> save(VmProfile p);
  Future<void> delete(String id);
}

int _byCreatedThenId(VmProfile a, VmProfile b) {
  final c = a.createdAt.compareTo(b.createdAt);
  return c != 0 ? c : a.id.compareTo(b.id);
}

/// Stores `<root>/vms/<id>/profile.json`, written atomically (temp file,
/// then rename) so a crash cannot corrupt the library.
///
/// [root] is the app documents directory. Profiles that fail to parse are
/// skipped by [loadAll]. Results are ordered by creation time, then id.
class FileVmRepository implements VmRepository {
  final Directory root;
  final ProfileSerializer _serializer;

  FileVmRepository(this.root, {ProfileSerializer? serializer})
    : _serializer = serializer ?? const ProfileSerializer();

  Directory get _vmsDir => Directory(p.join(root.path, 'vms'));

  Directory _dirFor(String id) => Directory(p.join(_vmsDir.path, id));

  File _profileFile(String id) =>
      File(p.join(_dirFor(id).path, 'profile.json'));

  @override
  Future<List<VmProfile>> loadAll() async {
    if (!await _vmsDir.exists()) return [];
    final result = <VmProfile>[];
    await for (final entity in _vmsDir.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final file = File(p.join(entity.path, 'profile.json'));
      if (!await file.exists()) continue;
      final parsed = _serializer.parse(await file.readAsString());
      if (parsed is Success) result.add(parsed.profile);
    }
    result.sort(_byCreatedThenId);
    return result;
  }

  @override
  Future<void> save(VmProfile profile) async {
    final dir = _dirFor(profile.id);
    await dir.create(recursive: true);
    final tmp = File(p.join(dir.path, 'profile.json.tmp'));
    await tmp.writeAsString(_serializer.print(profile), flush: true);
    await tmp.rename(_profileFile(profile.id).path);
  }

  @override
  Future<void> delete(String id) async {
    final dir = _dirFor(id);
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

/// In-memory repository for tests. Same ordering as [FileVmRepository].
class MemoryVmRepository implements VmRepository {
  final Map<String, VmProfile> _store = {};

  @override
  Future<List<VmProfile>> loadAll() async =>
      _store.values.toList()..sort(_byCreatedThenId);

  @override
  Future<void> save(VmProfile profile) async => _store[profile.id] = profile;

  @override
  Future<void> delete(String id) async => _store.remove(id);
}

/// Library queries (Req 10.3).
abstract final class LibrarySearch {
  /// Case-insensitive contains match on the name; an empty query keeps all.
  static List<VmProfile> filter(Iterable<VmProfile> profiles, String query) {
    final q = query.toLowerCase();
    return [
      for (final pr in profiles)
        if (q.isEmpty || pr.name.toLowerCase().contains(q)) pr,
    ];
  }
}

/// Clone naming (Req 10.4).
abstract final class CloneNamer {
  /// `"<name> copy"`, `"<name> copy 2"`, `"<name> copy 3"`, ... The first
  /// candidate not equal (case-insensitively) to an existing name.
  static String uniqueName(String sourceName, Iterable<String> existingNames) {
    final taken = {for (final n in existingNames) n.toLowerCase()};
    var candidate = '$sourceName copy';
    var n = 2;
    while (taken.contains(candidate.toLowerCase())) {
      candidate = '$sourceName copy $n';
      n++;
    }
    return candidate;
  }
}

/// Import rule (Req 10.6): keep the id unless the library already has it.
abstract final class ProfileImport {
  static VmProfile withFreshIdIfTaken(
    VmProfile imported,
    Iterable<String> existingIds,
    String Function() newId,
  ) {
    final ids = existingIds.toSet();
    if (!ids.contains(imported.id)) return imported;
    var id = newId();
    while (ids.contains(id)) {
      id = newId();
    }
    return imported.copyWith(id: id);
  }
}
