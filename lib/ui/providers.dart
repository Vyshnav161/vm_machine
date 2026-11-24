import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../controller/vm_manager_controller.dart';
import '../data/vm_repository.dart';
import '../domain/domain.dart';

/// The app's controller. `main` overrides this with the channel-backed
/// wiring (task 12.1); tests override it with fakes.
final vmManagerControllerProvider = Provider<VmManagerController>(
  (ref) => throw UnimplementedError(
    'vmManagerControllerProvider must be overridden',
  ),
);

/// Emits a new value on every profile or runtime change of the controller.
/// The value is a version counter; watchers rebuild and re-read the controller.
final vmChangesProvider = StreamProvider<int>((ref) async* {
  final controller = ref.watch(vmManagerControllerProvider);
  var n = 0;
  yield n;
  await for (final _ in controller.changes) {
    yield ++n;
  }
});

/// All profiles, refreshed on every controller change.
final vmLibraryProvider = Provider<List<VmProfile>>((ref) {
  ref.watch(vmChangesProvider);
  return ref.watch(vmManagerControllerProvider).profiles;
});

class LibraryQueryNotifier extends Notifier<String> {
  @override
  String build() => '';

  void set(String query) => state = query;
}

/// Search text of the library screen (Req 10.3).
final libraryQueryProvider = NotifierProvider<LibraryQueryNotifier, String>(
  LibraryQueryNotifier.new,
);

/// Profiles matching [libraryQueryProvider].
final filteredLibraryProvider = Provider<List<VmProfile>>((ref) {
  return LibrarySearch.filter(
    ref.watch(vmLibraryProvider),
    ref.watch(libraryQueryProvider),
  );
});

/// One profile by id, or null once deleted.
final vmProfileProvider = Provider.family<VmProfile?, String>((ref, id) {
  ref.watch(vmChangesProvider);
  return ref.watch(vmManagerControllerProvider).profileOf(id);
});

/// Runtime data (state, error reason, failure) for one VM.
final vmRuntimeProvider = Provider.family<VmRuntime, String>((ref, id) {
  ref.watch(vmChangesProvider);
  return ref.watch(vmManagerControllerProvider).runtimeOf(id);
});

/// Lifecycle state of one VM.
final vmStateProvider = Provider.family<VmState, String>(
  (ref, id) => ref.watch(vmRuntimeProvider(id)).state,
);

/// Notices from the resource policy (thermal, battery, storage).
final hostNoticeProvider = StreamProvider<HostNotice>(
  (ref) => ref.watch(vmManagerControllerProvider).notices,
);
