import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Splash screen displayed during app initialization
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.anchor,
              size: 80,
              color: AppTheme.primaryLight,
            ),
            SizedBox(height: 24),
            CircularProgressIndicator(
              color: AppTheme.primaryLight,
            ),
          ],
        ),
      ),
    );
  }
}
