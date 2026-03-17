import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'core/routing/app_shell.dart';
import 'core/theme/app_theme.dart';
import 'features/discovery/bloc/discovery_bloc.dart';
import 'features/profile/bloc/profile_bloc.dart';
import 'features/profile/bloc/profile_event.dart';
import 'features/transport/bloc/transport_bloc.dart';
import 'injection.dart';
import 'services/ble/ble.dart';

/// Main application widget
class AnchorApp extends StatelessWidget {
  const AnchorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider<ProfileBloc>(
          create: (_) => getIt<ProfileBloc>()..add(const LoadProfile()),
        ),
        BlocProvider<DiscoveryBloc>(
          create: (_) => getIt<DiscoveryBloc>(),
        ),
        BlocProvider<BleConnectionBloc>(
          create: (_) => getIt<BleConnectionBloc>()..add(const InitializeBleConnection()),
        ),
        BlocProvider<BleStatusBloc>(
          create: (_) => getIt<BleStatusBloc>(),
        ),
        BlocProvider<TransportBloc>(
          create: (_) => getIt<TransportBloc>(),
        ),
      ],
      child: MaterialApp(
        title: 'Anchor',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.darkTheme,
        home: const AppShell(),
      ),
    );
  }
}
