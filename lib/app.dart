import 'package:anchor/core/routing/app_shell.dart';
import 'package:anchor/core/theme/app_theme.dart';
import 'package:anchor/features/discovery/bloc/discovery_bloc.dart';
import 'package:anchor/features/profile/bloc/profile_bloc.dart';
import 'package:anchor/features/profile/bloc/profile_event.dart';
import 'package:anchor/features/transport/bloc/transport_bloc.dart';
import 'package:anchor/injection.dart';
import 'package:anchor/services/ble/ble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

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
