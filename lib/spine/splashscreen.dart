// import 'package:flutter/material.dart';
// import 'package:odoo_mobile/constants/color_constants.dart';
// import 'package:odoo_mobile/spine/webview.dart';

// class SplashScreen extends StatefulWidget {
//   const SplashScreen({super.key});

//   @override
//   State<SplashScreen> createState() => _SplashScreenState();
// }

// class _SplashScreenState extends State<SplashScreen> {
//   @override
//   void initState() {
//     super.initState();
//     final navigator = Navigator.of(context);
//     Future.delayed(Duration(seconds: 600), () {
//       navigator.pushReplacement(
//         MaterialPageRoute(builder: (context) => Webview()),
//       );
//     });
//   }

//   @override
//   Widget build(BuildContext context) {
//     return Scaffold(
//       backgroundColor: primaryColor,
//       body: Center(
//         child: Row(
//           mainAxisAlignment: MainAxisAlignment.center,
//           children: [
//             Image.asset(
//               'assets/wasla.png',
//               fit: BoxFit.contain,
//               height: 100,
//               width: 100,
//             ),
//             Text(
//               "Welcome to Odoo Mobile",
//               style: TextStyle(
//                 fontSize: 20,
//                 fontWeight: FontWeight.bold,
//                 color: whiteColor,
//               ),
//             ),
//           ],
//         ),
//       ),
//     );
//   }
// }

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:odoo_mobile/constants/color_constants.dart';
import 'package:odoo_mobile/spine/loginscreen.dart';
import 'package:odoo_mobile/spine/webview.dart';
import 'package:odoo_mobile/services/account_manager.dart';
import 'package:odoo_mobile/services/gps_tracking_service.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late AnimationController _logoCtrl;
  late AnimationController _textCtrl;

  late Animation<double> _logoFade;
  late Animation<double> _logoScale;

  late Animation<double> _textFade;

  @override
  void initState() {
    super.initState();

    // --- Logo Animation ---
    _logoCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    _logoFade = Tween(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _logoCtrl, curve: Curves.easeOut));

    _logoScale = Tween(
      begin: 0.6,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _logoCtrl, curve: Curves.elasticOut));

    // --- Text Animation ---
    _textCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );

    _textFade = Tween(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _textCtrl, curve: Curves.easeOut));

    // Sequence: Logo → then Text
    _logoCtrl.forward().then((_) {
      _textCtrl.forward();
    });

    // Navigate after animation

    final navigator = Navigator.of(context);
    Future.delayed(const Duration(milliseconds: 2800), () async {
      await AccountManager.instance.init();
      
      if (!mounted) return;

      if (AccountManager.instance.activeAccount != null) {
        final success = await AccountManager.instance.switchAccount(AccountManager.instance.activeAccount!.id, context);
        if (success && mounted) {
          await GpsTrackingService.instance.initialize();
          if (!mounted) return;
          navigator.pushReplacement(
            PageRouteBuilder(
              pageBuilder: (_, __, ___) => Webview(),
              transitionsBuilder: (_, anim, __, child) =>
                  FadeTransition(opacity: anim, child: child),
              transitionDuration: const Duration(milliseconds: 500),
            ),
          );
        } else if (mounted) {
          navigator.pushReplacement(
            PageRouteBuilder(
              pageBuilder: (_, __, ___) => const LoginScreen(isAddingAccount: false),
              transitionsBuilder: (_, anim, __, child) =>
                  FadeTransition(opacity: anim, child: child),
              transitionDuration: const Duration(milliseconds: 500),
            ),
          );
        }
      } else {
        navigator.pushReplacement(
          PageRouteBuilder(
            pageBuilder: (_, __, ___) => const LoginScreen(isAddingAccount: false),
            transitionsBuilder: (_, anim, __, child) =>
                FadeTransition(opacity: anim, child: child),
            transitionDuration: const Duration(milliseconds: 500),
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    _logoCtrl.dispose();
    _textCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        color: secondaryColor,
        alignment: Alignment.center,
        child: AnimatedBuilder(
          animation: Listenable.merge([_logoCtrl, _textCtrl]),
          builder: (_, __) {
            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // LOGO
                Opacity(
                  opacity: _logoFade.value,
                  child: Transform.scale(
                    scale: _logoScale.value,
                    child: Container(
                      padding: const EdgeInsets.all(2.5),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.15),
                            blurRadius: 18,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: ClipOval(
                        child: Image.asset(
                          "assets/wasla_logo.png",
                          height: 82,
                          width: 82,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 20),

                // TEXT (appears AFTER logo)
                Opacity(
                  opacity: _textFade.value,
                  child: Column(
                    children: [
                      const SizedBox(height: 4),
                      Text(
                        "Powered by Febno",
                        style: GoogleFonts.poppins(
                          fontSize: 14,
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
