import 'package:anchor/core/utils/logger.dart';
import 'package:anchor/services/ble/ble.dart';
import 'package:flutter/widgets.dart';

/// Observer that handles app lifecycle changes for BLE
///
/// Use this in your main app widget to respond to foreground/background transitions:
/// ```dart
/// WidgetsBinding.instance.addObserver(AppLifecycleObserver(
///   bleConnectionBloc: context.read<BleConnectionBloc>(),
/// ));
/// ```
class AppLifecycleObserver extends WidgetsBindingObserver {
  AppLifecycleObserver({
    required this.bleConnectionBloc,
    this.onResume,
    this.onPause,
  });

  final BleConnectionBloc bleConnectionBloc;
  final VoidCallback? onResume;
  final VoidCallback? onPause;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        Logger.info('AppLifecycleObserver: App resumed', 'Lifecycle');
        bleConnectionBloc.add(const AppResumed());
        onResume?.call();

      case AppLifecycleState.paused:
        Logger.info('AppLifecycleObserver: App paused', 'Lifecycle');
        bleConnectionBloc.add(const AppPaused());
        onPause?.call();

      case AppLifecycleState.inactive:
        Logger.info('AppLifecycleObserver: App inactive', 'Lifecycle');

      case AppLifecycleState.detached:
        Logger.info('AppLifecycleObserver: App detached', 'Lifecycle');

      case AppLifecycleState.hidden:
        Logger.info('AppLifecycleObserver: App hidden', 'Lifecycle');
    }
  }
}

/// Mixin for StatefulWidget to easily handle lifecycle
///
/// Usage:
/// ```dart
/// class _MyWidgetState extends State<MyWidget> with AppLifecycleMixin {
///   @override
///   void onAppResumed() {
///     // Handle resume
///   }
///
///   @override
///   void onAppPaused() {
///     // Handle pause
///   }
/// }
/// ```
mixin AppLifecycleMixin<T extends StatefulWidget> on State<T>
    implements WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        onAppResumed();
      case AppLifecycleState.paused:
        onAppPaused();
      case AppLifecycleState.inactive:
        onAppInactive();
      case AppLifecycleState.detached:
        onAppDetached();
      case AppLifecycleState.hidden:
        onAppHidden();
    }
  }

  /// Called when app comes to foreground
  void onAppResumed() {}

  /// Called when app goes to background
  void onAppPaused() {}

  /// Called when app becomes inactive (e.g., phone call)
  void onAppInactive() {}

  /// Called when app is detached
  void onAppDetached() {}

  /// Called when app is hidden
  void onAppHidden() {}

  // Required WidgetsBindingObserver methods with default implementations
  @override
  void didChangeAccessibilityFeatures() {}

  @override
  void didChangeLocales(List<Locale>? locales) {}

  @override
  void didChangeMetrics() {}

  @override
  void didChangePlatformBrightness() {}

  @override
  void didChangeTextScaleFactor() {}

  @override
  void didHaveMemoryPressure() {}

  @override
  Future<bool> didPopRoute() => Future.value(false);

  @override
  Future<bool> didPushRoute(String route) => Future.value(false);

  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) =>
      Future.value(false);
}
