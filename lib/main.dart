import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'screens/login_screen.dart';
import 'services/local_notification_service.dart';
import 'services/session_service.dart';
import 'bottom_navbar.dart';

// Global notifier: holds the logged-in user row (from the users table) or null.
final ValueNotifier<Map<String, dynamic>?> currentUserNotifier =
    ValueNotifier(null);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Supabase
  await Supabase.initialize(
    url: 'https://xrjsgesoikigalyrunek.supabase.co',
    anonKey:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhyanNnZXNvaWtpZ2FseXJ1bmVrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzMyMTg4NDAsImV4cCI6MjA4ODc5NDg0MH0.WoDuRdorVrKpI7NLOb8Hi3YB4_oqVX3oLo84bk10REU',
  );

  // Initialize local notifications used for medication alarms.
  await LocalNotificationService.initialize();

  // Restore user session so login is not required on every app restart.
  currentUserNotifier.value = await SessionService.restoreLoggedInUser();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Arogion',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF158CE8),
        ),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      home: const AuthWrapper(),
    );
  }
}

class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, dynamic>?>(
      valueListenable: currentUserNotifier,
      builder: (context, user, _) {
        if (user != null) {
          return const BottomNavBar();
        }
        return const LoginScreen();
      },
    );
  }
}
