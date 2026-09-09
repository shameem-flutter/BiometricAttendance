import 'package:flutter/material.dart';
import 'package:odoo_mobile/spine/splashscreen.dart';
import 'package:odoo_mobile/spine/loginscreen.dart';
import 'package:odoo_mobile/spine/webview.dart';
import 'package:odoo_mobile/spine/attendance_screen.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Wasla-Hr',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: SplashScreen(),
      routes: {
        "/webview": (_) => const Webview(),
        "/login": (_) => const LoginScreen(),
        "/attendance": (_) => const AttendanceScreen(),
      },
    );
  }
}
