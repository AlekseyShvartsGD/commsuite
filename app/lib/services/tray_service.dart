import 'dart:async';
import 'dart:io';
import 'dart:ui' show Offset, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/localizations.dart';

/// Keeps the app alive in the system tray when the window's close button is
/// pressed (Windows: real tray icon; Linux: ayatana-appindicator status icon in
/// the panel). The Dart isolate keeps running underneath, so incoming
/// calls/messages keep arriving while the window is hidden.
class TrayService with TrayListener, WindowListener {
  TrayService._();

  static final TrayService instance = TrayService._();

  bool _available = false;

  /// Set by main() when the app was launched with `--background` (autostart
  /// at login): after the callback, initTray() hides the window right away.
  bool requestStartHidden = false;

  /// Whether the tray icon + menu have been installed and can be refreshed.
  bool _ready = false;

  bool _connected = false;

  /// Called once from main() BEFORE runApp: sets the window to "prevent close"
  /// so pressing X hides instead of terminating the process.
  Future<void> initWindow() async {
    if (kIsWeb || !(Platform.isWindows || Platform.isLinux)) return;
    _available = true;
    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    try {
      await windowManager.setPreventClose(true);
    } catch (_) {}
  }

  /// Called after the first frame (window now exists): installs the tray icon
  /// and its menu. Windows uses an .ico, Linux a PNG (appindicator cannot
  /// decode .ico).
  Future<void> initTray() async {
    if (!_available) return;
    try {
      final isLinux = Platform.isLinux;
      final bytes = await rootBundle.load(
        isLinux ? 'assets/icons/tray.png' : 'assets/icons/tray.ico',
      );
      final dir = await getApplicationSupportDirectory();
      final iconFile = File(
        '${dir.path}${Platform.pathSeparator}${isLinux ? 'tray.png' : 'tray.ico'}',
      );
      await iconFile.writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        flush: true,
      );
      TrayManager.instance.addListener(this);
      await TrayManager.instance.setIcon(iconFile.path);
      await _refreshMenu();
      _ready = true;
      if (requestStartHidden) {
        await windowManager.hide();
      }
    } catch (_) {}
  }

  /// (Re)builds the tray tooltip and right-click menu. Re-called whenever the
  /// realtime connection status changes so the menu shows live state.
  Future<void> _refreshMenu() async {
    if (Platform.isLinux) {
      // appindicator has no tooltip; setTitle renders a short label next to
      // the icon instead (setToolTip is not implemented by the Linux plugin).
      await TrayManager.instance.setTitle(
        _connected
            ? L.t('Commsuite — online', ru: 'Commsuite — в сети')
            : L.t('Commsuite — offline', ru: 'Commsuite — не в сети'),
      );
    } else {
      await TrayManager.instance.setToolTip(
        _connected
            ? L.t('Commsuite — online', ru: 'Commsuite — в сети')
            : L.t('Commsuite — offline', ru: 'Commsuite — не в сети'),
      );
    }
    await TrayManager.instance.setContextMenu(
      Menu(
        items: [
          MenuItem(
            key: 'show',
            label: L.t('Show Commsuite', ru: 'Показать Commsuite'),
          ),
          MenuItem.separator(),
          MenuItem.checkbox(
            key: 'status',
            label: _connected
                ? L.t('Active', ru: 'Активен')
                : L.t('Offline', ru: 'Не в сети'),
            checked: _connected,
            disabled: true,
          ),
          MenuItem.separator(),
          MenuItem(
            key: 'exit',
            label: L.t('Exit', ru: 'Выход'),
          ),
        ],
      ),
    );
  }

  /// Called by CommsController whenever the realtime socket state changes.
  void setConnectionStatus(bool connected) {
    _connected = connected;
    if (_ready) {
      unawaited(_refreshMenu());
    }
  }

  /// Whether the main window is currently shown (Windows toasts are only
  /// posted while it is hidden in the tray, so an open window is not flooded
  /// with duplicates of the in-app banner).
  Future<bool> isWindowVisible() async {
    if (!_available) return true;
    try {
      return await windowManager.isVisible();
    } catch (_) {
      return true;
    }
  }

  Future<void> _bringToFront() async {
    await windowManager.show();
    await windowManager.focus();
  }

  /// Restores the (possibly hidden) window and pins it to the top-center of
  /// the screen, so incoming calls/messages land in the same spot the in-app
  /// top-center banners use. [stayOnTop] keeps it over other windows for the
  /// duration of a ringing call; [onlyIfHidden] skips windows that are already
  /// visible (used for message pings so an open window is not yanked around).
  Future<void> bringToFrontTopCenter({
    bool stayOnTop = false,
    bool onlyIfHidden = false,
  }) async {
    if (!_available) return;
    try {
      if (onlyIfHidden) {
        final visible = await windowManager.isVisible();
        if (visible) return;
      }
      await windowManager.show();
      await windowManager.restore();
      if (stayOnTop) await windowManager.setAlwaysOnTop(true);
      final size = await windowManager.getSize();
      final view = PlatformDispatcher.instance.views.first;
      final screen = view.physicalSize / view.devicePixelRatio;
      final x = ((screen.width - size.width) / 2).clamp(
        0.0,
        screen.width - size.width,
      );
      final y = 12.0;
      await windowManager.setPosition(Offset(x, y));
      await windowManager.focus();
    } catch (_) {}
  }

  /// Drops the window off the top of the z-order once the call ends.
  Future<void> releaseCallFocus() async {
    if (!_available) return;
    try {
      await windowManager.setAlwaysOnTop(false);
    } catch (_) {}
  }

  Future<void> _exit() async {
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  // ---- TrayListener ----

  @override
  void onTrayIconMouseDown() {
    _bringToFront();
  }

  @override
  void onTrayIconMouseUp() {
    _bringToFront();
  }

  @override
  void onTrayIconRightMouseDown() {
    // Linux (appindicator): the menu is popped by the panel itself on click,
    // and popUpContextMenu is not implemented there — nothing to do.
    if (Platform.isLinux) return;
    // The native plugin does NOT auto-pop the menu on right-click; it only
    // fires this event, so the menu has to be shown from here.
    // ignore: deprecated_member_use
    unawaited(TrayManager.instance.popUpContextMenu(bringAppToFront: true));
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        _bringToFront();
        break;
      case 'exit':
        _exit();
        break;
    }
  }

  // ---- WindowListener ----

  @override
  void onWindowClose() {
    // Prevented close: keep the app running in the background instead.
    windowManager.hide();
  }
}
