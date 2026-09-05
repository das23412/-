import 'package:flutter_test/flutter_test.dart';
import 'package:moyue/services/update_service.dart';

void main() {
  group('版本号归一化', () {
    test('去掉 v 前缀', () {
      expect(UpdateService.normalizeVersion('v1.3.0'), '1.3.0');
      expect(UpdateService.normalizeVersion('V2.0.1'), '2.0.1');
      expect(UpdateService.normalizeVersion('1.4.2'), '1.4.2');
      expect(UpdateService.normalizeVersion(' v1.5.0 '), '1.5.0');
    });
  });

  group('版本比较', () {
    test('大于', () {
      expect(UpdateService.compareVersions('1.3.0', '1.2.9'), 1);
      expect(UpdateService.compareVersions('2.0.0', '1.9.9'), 1);
      expect(UpdateService.compareVersions('1.3.1', '1.3.0'), 1);
    });

    test('相等', () {
      expect(UpdateService.compareVersions('1.3.0', '1.3.0'), 0);
      expect(UpdateService.compareVersions('1.3', '1.3.0'), 0);
    });

    test('小于', () {
      expect(UpdateService.compareVersions('1.2.9', '1.3.0'), -1);
      expect(UpdateService.compareVersions('0.9.0', '1.0.0'), -1);
    });
  });
}
