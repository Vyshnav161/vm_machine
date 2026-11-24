import 'package:vm_machine/domain/domain.dart';
import 'package:vm_machine/services/services.dart';

class FakeHostProbe implements HostProbeService {
  HostCapabilities capabilities;
  bool notificationsGranted;
  Object? failWith;
  int probeCalls = 0;

  FakeHostProbe({
    this.capabilities = const HostCapabilities(),
    this.notificationsGranted = true,
  });

  @override
  Future<HostCapabilities> probe() async {
    probeCalls++;
    if (failWith != null) throw failWith!;
    return capabilities;
  }

  @override
  Future<bool> requestNotificationPermission() async => notificationsGranted;
}
