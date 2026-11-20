import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/app_state.dart';
import 'package:open_builder/core/platform/keepalive_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingBackend extends KeepaliveBackend {
  final starts = <int>[];
  int stops = 0;
  void Function()? unpinHandler;

  @override
  Future<void> start(int count) async => starts.add(count);

  @override
  Future<void> updateCount(int count) async {}

  @override
  Future<void> stop() async => stops++;

  @override
  Future<bool> notificationsEnabled() async => true;

  @override
  void setUnpinHandler(void Function()? onUnpin) => unpinHandler = onUnpin;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  bool savedToggle = false;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    savedToggle = taskCompleteNotify.value;
  });

  tearDown(() {
    KeepaliveController.I.disposeForTesting();
    taskCompleteNotify.value = savedToggle;
  });

  test('init registers the notification unpin handler; dispose clears it',
      () {
    final backend = _RecordingBackend();
    KeepaliveController.I.init(backend: backend);
    expect(backend.unpinHandler, isNotNull);

    KeepaliveController.I.disposeForTesting();
    expect(backend.unpinHandler, isNull);
  });

  test('unpin from notification flips the master toggle off and stops the fgs',
      () async {
    final backend = _RecordingBackend();
    KeepaliveController.I.init(backend: backend);

    taskCompleteNotify.value = true;
    KeepaliveController.I.armOnUserPromptSent();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(KeepaliveController.I.fgsOnForTesting, isTrue);

    backend.unpinHandler!();
    expect(taskCompleteNotify.value, isFalse);
    expect(KeepaliveController.I.fgsOnForTesting, isFalse);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(backend.stops, 1);
  });
}
