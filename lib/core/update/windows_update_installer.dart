import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:THLRedLook/core/update/app_update_service.dart';
import 'package:THLRedLook/utils/diary/diary_service.dart';

/// Windows 软件内更新：下载 zip → 解压 → 退出本程序 → 脚本覆盖安装目录 → 自动重启。
/// 只覆盖、不删除安装目录里的文件；用户数据不在安装目录内，不受影响。
class WindowsUpdateInstaller {
  WindowsUpdateInstaller._();

  /// 成功后会直接退出本程序并由脚本重启；失败时抛出异常。
  static Future<void> downloadAndInstall(
    UpdateAsset asset, {
    required void Function(double? progress, String stage) onProgress,
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('仅支持 Windows');
    }
    final appDir = p.dirname(Platform.resolvedExecutable);
    final work = Directory(p.join(Directory.systemTemp.path, 'florist_update'));
    if (await work.exists()) {
      try {
        await work.delete(recursive: true);
      } catch (_) {}
    }
    await work.create(recursive: true);

    // 1. 下载
    final zip = File(p.join(work.path, 'update.zip'));
    final client = http.Client();
    try {
      onProgress(0, '正在下载 ${asset.name}');
      final response = await client
          .send(http.Request('GET', Uri.parse(asset.downloadUrl)))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw HttpException('下载失败（HTTP ${response.statusCode}）');
      }
      final total = response.contentLength ?? asset.sizeBytes;
      var received = 0;
      final sink = zip.openWrite();
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          final done = (received / 1048576).toStringAsFixed(1);
          final all = total > 0 ? (total / 1048576).toStringAsFixed(1) : '?';
          onProgress(
            total > 0 ? received / total : null,
            '正在下载 $done / $all MB',
          );
        }
      } finally {
        await sink.close();
      }
      if (total > 0 && received < total) {
        throw const HttpException('下载不完整，请重试');
      }
    } finally {
      client.close();
    }

    // 2. 解压（Windows 自带 PowerShell）
    onProgress(null, '正在解压…');
    final extract = Directory(p.join(work.path, 'new'));
    String quote(String path) => path.replaceAll("'", "''");
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      "Expand-Archive -LiteralPath '${quote(zip.path)}' "
          "-DestinationPath '${quote(extract.path)}' -Force",
    ]);
    if (result.exitCode != 0) {
      throw ProcessException(
        'powershell',
        const [],
        '解压失败：${result.stderr}',
        result.exitCode,
      );
    }
    final exes = extract
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.exe'))
        .map((f) => p.basename(f.path))
        .toList();
    if (exes.isEmpty ||
        !File(p.join(extract.path, 'data', 'app.so')).existsSync()) {
      throw const FormatException('更新包内容不完整，已取消更新');
    }
    final currentExe = p.basename(Platform.resolvedExecutable);
    final newExe = exes.contains(currentExe) ? currentExe : exes.first;

    // 3. 写覆盖安装脚本并启动，然后退出本程序
    onProgress(1, '正在安装，程序将自动重启…');
    final script = File(p.join(work.path, 'apply_update.bat'));
    final bat = [
      '@echo off',
      'chcp 65001 >nul',
      'set "WAITPID=$pid"',
      ':wait',
      'tasklist /FI "PID eq %WAITPID%" 2>nul | find "%WAITPID%" >nul',
      'if not errorlevel 1 (',
      '  timeout /t 1 /nobreak >nul',
      '  goto wait',
      ')',
      'robocopy "${extract.path}" "$appDir" /E /R:5 /W:1 /NFL /NDL /NJH /NJS /NP >nul',
      'start "" "${p.join(appDir, newExe)}"',
      '',
    ].join('\r\n');
    await script.writeAsString(bat, flush: true);
    DiaryService.add('[更新] 已下载 ${asset.name}，退出后覆盖安装并重启');
    await Process.start(
      'cmd.exe',
      ['/c', script.path],
      mode: ProcessStartMode.detached,
    );
    await Future<void>.delayed(const Duration(milliseconds: 400));
    exit(0);
  }
}
