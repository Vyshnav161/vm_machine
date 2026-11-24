import 'dart:convert';

import '../domain/domain.dart';

/// Why a profile file could not be parsed (Req 10.7).
class ParseError {
  /// The offending field (dotted path, e.g. `disks[0].path`), if any.
  final String? field;

  /// The `schemaVersion` found in the file when it is not supported.
  final int? unsupportedVersion;
  final String message;

  const ParseError({
    this.field,
    this.unsupportedVersion,
    required this.message,
  });

  @override
  String toString() => 'ParseError($message)';
}

sealed class ParseResult {
  const ParseResult();
}

class Success extends ParseResult {
  final VmProfile profile;
  const Success(this.profile);
}

class Failure extends ParseResult {
  final ParseError error;
  const Failure(this.error);
}

class _FieldException implements Exception {
  final String field;
  final String message;
  _FieldException(this.field, this.message);
}

/// Prints and parses VM_Profile_File JSON (schema version 1).
///
/// Output is deterministic: keys are sorted and the text is indented.
/// `status` fields are never written; parsed items are [MediaStatus.present].
/// `createdAt` is stored and restored as UTC.
class ProfileSerializer {
  const ProfileSerializer();

  static const int schemaVersion = 1;

  /// Profile_Printer.
  String print(VmProfile p) {
    final map = <String, Object?>{
      'schemaVersion': schemaVersion,
      'id': p.id,
      'name': p.name,
      'guestOs': p.guestOs.name,
      'guestArch': p.guestArch.name,
      'cpuCount': p.cpuCount,
      'memoryMiB': p.memoryMiB,
      'disks': [
        for (final d in p.disks)
          {
            'path': d.path,
            'virtualSizeBytes': d.virtualSizeBytes,
            'format': d.format,
          },
      ],
      'media': [
        for (final m in p.media)
          {
            'path': m.path,
            'kind': m.kind.name,
            'copied': m.copiedIntoAppStorage,
            if (m.displayName != null) 'displayName': m.displayName,
          },
      ],
      'network': {
        'mode': p.network.mode.name,
        'forwards': [
          for (final f in p.network.forwards)
            {'hostPort': f.hostPort, 'guestPort': f.guestPort},
        ],
      },
      'sharedFolders': [
        for (final s in p.sharedFolders)
          {'androidPath': s.androidPath, 'mountTag': s.mountTag},
      ],
      'batterySaver': p.batterySaver,
      'licenseAcknowledged': p.licenseAcknowledged,
      'createdAt': p.createdAt.toUtc().toIso8601String(),
    };
    return const JsonEncoder.withIndent('  ').convert(_sorted(map));
  }

  static Object? _sorted(Object? v) {
    if (v is Map) {
      final keys = v.keys.cast<String>().toList()..sort();
      return {for (final k in keys) k: _sorted(v[k])};
    }
    if (v is List) return [for (final e in v) _sorted(e)];
    return v;
  }

  /// Parser. Never throws for bad input.
  ParseResult parse(String json) {
    final Object? root;
    try {
      root = jsonDecode(json);
    } on FormatException catch (e) {
      return Failure(ParseError(message: 'Invalid JSON: ${e.message}'));
    }
    if (root is! Map<String, dynamic>) {
      return const Failure(
        ParseError(message: 'Profile file must be a JSON object'),
      );
    }
    try {
      final version = root['schemaVersion'];
      if (!root.containsKey('schemaVersion')) {
        throw _FieldException('schemaVersion', 'is missing');
      }
      if (version is! int) {
        throw _FieldException('schemaVersion', 'must be an integer');
      }
      if (version != schemaVersion) {
        return Failure(
          ParseError(
            field: 'schemaVersion',
            unsupportedVersion: version,
            message:
                'Unsupported schemaVersion $version '
                '(supported: $schemaVersion)',
          ),
        );
      }
      return Success(_profile(root));
    } on _FieldException catch (e) {
      return Failure(
        ParseError(
          field: e.field,
          message: 'Invalid field "${e.field}": ${e.message}',
        ),
      );
    }
  }

  VmProfile _profile(Map<String, dynamic> m) {
    return VmProfile(
      id: _str(m, 'id', 'id'),
      name: _str(m, 'name', 'name'),
      guestOs: _enum(GuestOs.values, m, 'guestOs', 'guestOs'),
      guestArch: _enum(GuestArch.values, m, 'guestArch', 'guestArch'),
      cpuCount: _int(m, 'cpuCount', 'cpuCount'),
      memoryMiB: _int(m, 'memoryMiB', 'memoryMiB'),
      disks: _list(
        m,
        'disks',
        'disks',
        (e, p) => DiskRef(
          path: _str(e, 'path', '$p.path'),
          virtualSizeBytes: _int(e, 'virtualSizeBytes', '$p.virtualSizeBytes'),
          format: _str(e, 'format', '$p.format'),
        ),
      ),
      media: _list(
        m,
        'media',
        'media',
        (e, p) => MediaRef(
          path: _str(e, 'path', '$p.path'),
          kind: _enum(MediaKind.values, e, 'kind', '$p.kind'),
          copiedIntoAppStorage: _bool(e, 'copied', '$p.copied'),
          displayName: e['displayName'] is String
              ? e['displayName'] as String
              : null,
        ),
      ),
      network: _network(m),
      sharedFolders: _list(
        m,
        'sharedFolders',
        'sharedFolders',
        (e, p) => SharedFolder(
          androidPath: _str(e, 'androidPath', '$p.androidPath'),
          mountTag: _str(e, 'mountTag', '$p.mountTag'),
        ),
      ),
      batterySaver: _bool(m, 'batterySaver', 'batterySaver'),
      licenseAcknowledged: _bool(
        m,
        'licenseAcknowledged',
        'licenseAcknowledged',
      ),
      createdAt: _date(m, 'createdAt', 'createdAt'),
    );
  }

  NetworkConfig _network(Map<String, dynamic> m) {
    final n = _obj(m, 'network', 'network');
    return NetworkConfig(
      mode: _enum(NetworkMode.values, n, 'mode', 'network.mode'),
      forwards: _list(
        n,
        'forwards',
        'network.forwards',
        (e, p) => PortForward(
          hostPort: _int(e, 'hostPort', '$p.hostPort'),
          guestPort: _int(e, 'guestPort', '$p.guestPort'),
        ),
      ),
    );
  }

  Object _req(Map<String, dynamic> m, String key, String path) {
    final v = m[key];
    if (v == null) throw _FieldException(path, 'is missing');
    return v;
  }

  String _str(Map<String, dynamic> m, String key, String path) {
    final v = _req(m, key, path);
    if (v is! String) throw _FieldException(path, 'must be a string');
    return v;
  }

  int _int(Map<String, dynamic> m, String key, String path) {
    final v = _req(m, key, path);
    if (v is! int) throw _FieldException(path, 'must be an integer');
    return v;
  }

  bool _bool(Map<String, dynamic> m, String key, String path) {
    final v = _req(m, key, path);
    if (v is! bool) throw _FieldException(path, 'must be a boolean');
    return v;
  }

  Map<String, dynamic> _obj(Map<String, dynamic> m, String key, String path) {
    final v = _req(m, key, path);
    if (v is! Map<String, dynamic>) {
      throw _FieldException(path, 'must be an object');
    }
    return v;
  }

  T _enum<T extends Enum>(
    List<T> values,
    Map<String, dynamic> m,
    String key,
    String path,
  ) {
    final s = _str(m, key, path);
    for (final v in values) {
      if (v.name == s) return v;
    }
    throw _FieldException(path, 'unknown value "$s"');
  }

  DateTime _date(Map<String, dynamic> m, String key, String path) {
    final s = _str(m, key, path);
    final d = DateTime.tryParse(s);
    if (d == null) throw _FieldException(path, 'must be an ISO 8601 date');
    return d.toUtc();
  }

  List<T> _list<T>(
    Map<String, dynamic> m,
    String key,
    String path,
    T Function(Map<String, dynamic> e, String p) build,
  ) {
    final v = _req(m, key, path);
    if (v is! List) throw _FieldException(path, 'must be a list');
    final out = <T>[];
    for (var i = 0; i < v.length; i++) {
      final e = v[i];
      if (e is! Map<String, dynamic>) {
        throw _FieldException('$path[$i]', 'must be an object');
      }
      out.add(build(e, '$path[$i]'));
    }
    return out;
  }
}
