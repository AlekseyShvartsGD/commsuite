import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'tray_service.dart';

import '../core/localizations.dart';

const _actionPortName = 'commsuite/notify-actions';

/// Windows unpackaged-app registration (registry + COM activator) uses this
/// fixed identity. The GUID follows the required xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx shape.
const _windowsAumid = 'com.commsuite.commsuite';
const _windowsGuid = '1f2e6b5a-9c3d-4e8f-b7a6-0d9c2e4f8a1b';

/// v19+ delivers notification ACTION taps through a dedicated background
/// isolate, not the main one. This entry point only relays the response back to
/// the main isolate (the actual handling happens in OsNotifications._onResponse).
@pragma('vm:entry-point')
void osNotificationsBackgroundHandler(NotificationResponse response) {
  final port = ui.IsolateNameServer.lookupPortByName(_actionPortName);
  port?.send(response);
}

/// OS-level notifications (Android heads-up / full-screen intents) so incoming
/// calls and messages stay visible while the app is NOT the front activity -
/// the in-app overlay banner only exists inside the app's own window.
///
/// Windows deliberately does not use this path: the window lives hidden in the
/// tray, so calls/messages bring it back on top and top-center instead
/// (see TrayService.bringToFrontTopCenter).
class OsNotifications {
  OsNotifications._();

  static final instance = OsNotifications._();

  static const _callsChannelId = 'calls';
  static const _messagesChannelId = 'messages';
  static const _callNotificationId = 1001;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final MethodChannel _frontChannel = const MethodChannel('commsuite/notify');
  ReceivePort? _actionListener;
  bool _ready = false;
  int _messageSeq = 0;

  /// Wired by CommsController. peerId lets the handlers check the incoming call
  /// is still the active one before accepting/declining.
  Future<void> Function(String peerId)? onCallAnswer;
  Future<void> Function(String peerId)? onCallDecline;
  void Function()? onOpen;

  static const _logPath =
      '/data/user/0/com.commsuite.commsuite/cache/osnotif.log';
  static Directory? _logDir;

  static Future<void> _ensureLogDir() async {
    if (_logDir != null || Platform.isAndroid) return;
    try {
      final dir = await getApplicationSupportDirectory();
      _logDir = Directory('${dir.path}${Platform.pathSeparator}logs');
      await _logDir!.create(recursive: true);
    } catch (_) {}
  }

  /// Debug trace appendable from anywhere via run-as on Android, or from the
  /// PC app's support dir on Windows (flushed immediately so it can be read
  /// after the fact).
  static void log(String msg) {
    try {
      File(_platformLogPath()).writeAsStringSync(
        '${DateTime.now().toIso8601String()} $msg\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }

  static String _platformLogPath() {
    if (Platform.isAndroid) return _logPath;
    final dir = _logDir;
    return dir == null ? '' : '${dir.path}${Platform.pathSeparator}osnotif.log';
  }

  Future<void> init() async {
    if (kIsWeb) return;
    if (!Platform.isAndroid && !Platform.isWindows) return;
    try {
      await _ensureLogDir();
      log('init: start os=${Platform.operatingSystem}');
      if (Platform.isAndroid) {
        _startActionListener();
      }
      final settings = InitializationSettings(
        android: Platform.isAndroid
            ? const AndroidInitializationSettings('@drawable/ic_stat_comm')
            : null,
        windows: Platform.isWindows ? await _windowsSettings() : null,
      );
      await _plugin.initialize(
        settings,
        onDidReceiveNotificationResponse: _onResponse,
        onDidReceiveBackgroundNotificationResponse:
            osNotificationsBackgroundHandler,
      );

      if (Platform.isAndroid) {
        final calls = AndroidNotificationChannel(
          _callsChannelId,
          L.t('Incoming calls', ru: 'Входящие звонки'),
          description: L.t(
            'Incoming call and video call alerts',
            ru: 'Оповещения о входящих звонках и видеозвонках',
          ),
          importance: Importance.max,
          playSound: true,
          enableVibration: true,
        );
        final messages = AndroidNotificationChannel(
          _messagesChannelId,
          L.t('Messages', ru: 'Сообщения'),
          description: L.t(
            'New message alerts',
            ru: 'Оповещения о новых сообщениях',
          ),
          importance: Importance.high,
          playSound: true,
        );
        final android = _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        await android?.createNotificationChannel(calls);
        await android?.createNotificationChannel(messages);
      }
      _ready = true;
      log('init: ok');
    } catch (e) {
      _ready = false;
      log('init: error $e');
    }
    await _requestPermission(android: true);
  }

  /// Windows needs a fixed app identity (AUMID) plus a COM-registered toast
  /// activator so toasts survive even though the app is not MSIX-packaged.
  Future<WindowsInitializationSettings> _windowsSettings() async {
    String? iconPath;
    try {
      final bytes = await rootBundle.load('assets/icons/toast.png');
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}${Platform.pathSeparator}toast.png');
      await f.writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        flush: true,
      );
      iconPath = Uri.file(f.path).toString();
    } catch (_) {}
    return WindowsInitializationSettings(
      appName: 'Commsuite',
      appUserModelId: _windowsAumid,
      guid: _windowsGuid,
      iconPath: iconPath,
    );
  }

  Future<void> _requestPermission({bool android = false}) async {
    if (!android || !Platform.isAndroid) return;
    try {
      if (await Permission.notification.isGranted) {
        log('perm: already granted');
        return;
      }
      final s = await Permission.notification.request();
      log('perm: request result $s');
    } catch (e) {
      log('perm: error $e');
    }
  }

  bool get ready => _ready;

  /// Receives action taps relayed from the plugin's background callback
  /// isolate and funnels them into the same handler as foreground taps.
  void _startActionListener() {
    _actionListener?.close();
    ui.IsolateNameServer.removePortNameMapping(_actionPortName);
    final port = ReceivePort();
    _actionListener = port;
    port.listen((dynamic message) {
      if (message is NotificationResponse) {
        unawaited(_onResponse(message));
      }
    });
    ui.IsolateNameServer.registerPortWithName(port.sendPort, _actionPortName);
  }

  /// True when the app is not the visible, interactive activity (backgrounded).
  bool get inBackground {
    final s = WidgetsBinding.instance.lifecycleState;
    return s == AppLifecycleState.paused ||
        s == AppLifecycleState.inactive ||
        s == AppLifecycleState.detached ||
        s == AppLifecycleState.hidden;
  }

  Future<void> showCall({
    required String peerId,
    required String displayName,
    required bool video,
  }) async {
    log('showCall: peer=$peerId video=$video ready=$_ready bg=$inBackground');
    if (!_ready) return;
    try {
      final details = NotificationDetails(
        android: AndroidNotificationDetails(
          _callsChannelId,
          L.t('Incoming calls', ru: 'Входящие звонки'),
          channelDescription: L.t(
            'Incoming call and video call alerts',
            ru: 'Оповещения о входящих звонках и видеозвонках',
          ),
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.call,
          fullScreenIntent: true,
          onlyAlertOnce: true,
          playSound: true,
          enableVibration: true,
          showWhen: false,
          actions: [
            AndroidNotificationAction(
              'call_answer',
              L.t('Answer', ru: 'Ответить'),
            ),
            AndroidNotificationAction(
              'call_decline',
              L.t('Decline', ru: 'Отклонить'),
            ),
          ],
        ),
        // Windows: scenario.incomingCall makes the toast expand with the
        // caller-format and loop the standard call sound. Button arguments are
        // relayed as the NotificationResponse.actionId (== payload on WinRT),
        // so they hit the same call_answer/call_decline handlers.
        windows: WindowsNotificationDetails(
          duration: WindowsNotificationDuration.long,
          scenario: WindowsNotificationScenario.incomingCall,
          actions: [
            WindowsAction(
              content: L.t('Answer', ru: 'Ответить'),
              arguments: 'call_answer',
            ),
            WindowsAction(
              content: L.t('Decline', ru: 'Отклонить'),
              arguments: 'call_decline',
              activationBehavior: WindowsNotificationBehavior.dismiss,
            ),
          ],
        ),
      );
      await _plugin.show(
        _callNotificationId,
        video
            ? L.t('Incoming video call', ru: 'Входящий видеозвонок')
            : L.t('Incoming call', ru: 'Входящий звонок'),
        displayName,
        details,
        payload: 'call:$peerId',
      );
      log('showCall: posted id=$_callNotificationId');
    } catch (e) {
      log('showCall: error $e');
    }
  }

  Future<void> showMessage({
    required String title,
    required String body,
  }) async {
    log('showMessage: title=$title ready=$_ready bg=$inBackground');
    if (!_ready) return;
    try {
      final details = NotificationDetails(
        android: AndroidNotificationDetails(
          _messagesChannelId,
          L.t('Messages', ru: 'Сообщения'),
          channelDescription: L.t(
            'New message alerts',
            ru: 'Оповещения о новых сообщениях',
          ),
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.message,
          playSound: true,
          enableVibration: true,
        ),
        windows: WindowsNotificationDetails(
          duration: WindowsNotificationDuration.long,
        ),
      );
      await _plugin.show(
        _callNotificationId + ++_messageSeq,
        title,
        body,
        details,
        payload: 'message',
      );
      log('showMessage: posted id=${_callNotificationId + _messageSeq}');
    } catch (e) {
      log('showMessage: error $e');
    }
  }

  Future<void> cancelCall() async {
    if (!_ready) return;
    try {
      await _plugin.cancel(_callNotificationId);
    } catch (_) {}
  }

  Future<void> cancelAll() async {
    if (!_ready) return;
    try {
      await _plugin.cancelAll();
    } catch (_) {}
  }

  /// Brings MainActivity to the front (Action launch itself does not resume the
  /// activity, and the Dart process keeps running underneath).
  Future<void> bringToFront() async {
    if (!Platform.isAndroid) return;
    try {
      await _frontChannel.invokeMethod('bringToFront');
    } catch (_) {}
  }

  Future<void> _onResponse(NotificationResponse response) async {
    log('response: action=${response.actionId} payload=${response.payload}');
    final peerId = response.payload?.startsWith('call:') == true
        ? response.payload!.substring(5)
        : null;
    try {
      switch (response.actionId) {
        case 'call_answer':
          await onCallAnswer?.call(peerId ?? '');
          break;
        case 'call_decline':
          await onCallDecline?.call(peerId ?? '');
          break;
        default:
          onOpen?.call();
      }
    } finally {
      if (Platform.isWindows) {
        // Un-hide the window so the result of the tap is visible.
        await TrayService.instance.bringToFrontTopCenter();
      } else {
        await bringToFront();
      }
    }
  }
}
