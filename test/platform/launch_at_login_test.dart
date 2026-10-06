import 'dart:io';

import 'package:flutter_airplay/platform/launch_at_login.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory fixture;
  late LinuxLoginEntry login;
  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('airplay-login-test-');
    final executable = File('${fixture.path}/Air Play "播放器"');
    await executable.writeAsString('fixture only; never executed');
    await Process.run('chmod', ['700', executable.path]);
    login = LinuxLoginEntry(
      environment: {'XDG_CONFIG_HOME': fixture.path},
      executable: executable.path,
    );
  });
  tearDown(() async {
    await fixture.delete(recursive: true);
  });

  test('query defaults off without creating registration; enable and disable round trip', () async {
    expect(await login.isEnabled(), false);
    expect(await login.entry.parent.exists(), false);
    expect(await login.setEnabled(true), true);
    expect(await login.setEnabled(false), false);
    expect(await login.entry.exists(), false);
  });
  test('external desktop disable is reflected', () async {
    await login.setEnabled(true);
    final original = await login.entry.readAsString();
    for (final content in [
      original.replaceAll('Hidden=false', 'Hidden=true'),
      original.replaceAll(
        'X-GNOME-Autostart-enabled=true',
        'X-GNOME-Autostart-enabled=false',
      ),
      '$original\nOnlyShowIn=KDE;\n',
      original.replaceAll('Exec=', 'Exec=/other '),
    ]) {
      await login.entry.writeAsString(content);
      expect(await login.isEnabled(), false);
    }
  });
  test(
    'AppImage uses permanent image rather than mounted executable',
    () async {
      final image = File('${fixture.path}/app.AppImage');
      await image.writeAsString('fixture');
      await Process.run('chmod', ['700', image.path]);
      final appImage = LinuxLoginEntry(
        environment: {'XDG_CONFIG_HOME': fixture.path, 'APPIMAGE': image.path},
        executable: '/tmp/.mount_example/usr/bin/app',
      );
      expect(await appImage.setEnabled(true), true);
      expect(
        await appImage.entry.readAsString(),
        contains('Exec="${image.path}"'),
      );
    },
  );
  test('system registration can be overridden off without deleting system file', () async {
    final system = Directory('${fixture.path}/system/autostart');
    await system.create(recursive: true);
    final systemFile = File('${system.path}/${LinuxLoginEntry.filename}');
    await systemFile.writeAsString(
      '[Desktop Entry]\nType=Application\nExec=${LinuxLoginEntry.quoteExecutable(login.appPath)}\n',
    );
    final layered = LinuxLoginEntry(
      environment: {
        'XDG_CONFIG_HOME': '${fixture.path}/user',
        'XDG_CONFIG_DIRS': '${fixture.path}/system',
      },
      executable: login.appPath,
    );
    expect(await layered.isEnabled(), true);
    expect(await layered.setEnabled(false), false);
    expect(await systemFile.exists(), true);
    expect(await layered.entry.readAsString(), contains('Hidden=true'));
    expect(await layered.setEnabled(true), true);
  });
  test('reads equivalent absolute and PATH registrations', () async {
    final binary = File('${fixture.path}/flutter_airplay');
    await binary.writeAsString('fixture');
    await Process.run('chmod', ['700', binary.path]);
    final actual = LinuxLoginEntry(
      environment: {'XDG_CONFIG_HOME': fixture.path, 'PATH': fixture.path},
      executable: binary.path,
    );
    await actual.entry.parent.create(recursive: true);
    for (final command in [
      binary.path,
      'flutter_airplay',
      '"${binary.path}"',
    ]) {
      await actual.entry.writeAsString(
        '[Desktop Entry]\nType=Application\nExec=$command\nTryExec=flutter_airplay\n',
      );
      expect(await actual.isEnabled(), true);
    }
  });
  test('empty system config variable uses the XDG default', () {
    expect(
      LinuxLoginEntry(environment: {'XDG_CONFIG_DIRS': ''})
          .systemEntries
          .single
          .path,
      '/etc/xdg/autostart/${LinuxLoginEntry.filename}',
    );
  });
  test('relative XDG path falls back to absolute HOME', () {
    final entry = LinuxLoginEntry(
      environment: {'HOME': fixture.path, 'XDG_CONFIG_HOME': 'relative'},
    );
    expect(
      entry.entry.path,
      '${fixture.path}/.config/autostart/${LinuxLoginEntry.filename}',
    );
  });
  test('rejects missing executable and unsafe path syntax', () async {
    final missing = LinuxLoginEntry(
      environment: {'XDG_CONFIG_HOME': fixture.path},
      executable: '/not-installed/app',
    );
    await expectLater(
      missing.setEnabled(true),
      throwsA(isA<FileSystemException>()),
    );
    for (final path in [
      'relative',
      '/app\nHidden=false',
      '/app=bad',
      '/app%u',
    ]) {
      expect(
        () => LinuxLoginEntry.quoteExecutable(path),
        throwsA(isA<FileSystemException>()),
      );
    }
  });
  test('Exec quotes both escaping layers', () {
    expect(
      LinuxLoginEntry.quoteExecutable(r'/a b/$x`"\'),
      r'"/a b/\\$x\\`\\"\\\\"',
    );
  });
  test(
    'non-executable or removed application is not reported enabled',
    () async {
      await login.setEnabled(true);
      await Process.run('chmod', ['600', login.appPath]);
      expect(await login.isEnabled(), false);
      await expectLater(
        login.setEnabled(true),
        throwsA(isA<FileSystemException>()),
      );
    },
  );
  test('never follows a startup entry symlink during writes', () async {
    await login.entry.parent.create(recursive: true);
    final target = File('${fixture.path}/unrelated');
    await target.writeAsString('untouched');
    await Link(login.entry.path).create(target.path);
    await expectLater(
      login.setEnabled(true),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      login.setEnabled(false),
      throwsA(isA<FileSystemException>()),
    );
    expect(await target.readAsString(), 'untouched');
  });
}
