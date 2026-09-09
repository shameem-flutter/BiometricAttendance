import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:odoo_mobile/constants/api_endpoint.dart';
import 'package:odoo_mobile/constants/color_constants.dart';
import 'package:odoo_mobile/constants/gap_func.dart';
import 'package:odoo_mobile/models/account_model.dart';
import 'package:odoo_mobile/services/account_manager.dart';
import 'package:odoo_mobile/services/api_services/authservice.dart';
import 'package:odoo_mobile/services/gps_tracking_service.dart';
import 'package:odoo_mobile/widgets/textformfield.dart';

class LoginScreen extends StatefulWidget {
  final bool isAddingAccount;
  const LoginScreen({super.key, this.isAddingAccount = false});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  TextEditingController urlCtrl = TextEditingController();
  TextEditingController dbCtrl = TextEditingController();
  TextEditingController usernameController = TextEditingController();
  TextEditingController passwordController = TextEditingController();

  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    urlCtrl.dispose();
    dbCtrl.dispose();
    usernameController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> saveConfig() async {
    final navigator = Navigator.of(context);
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    
    if (_formKey.currentState!.validate()) {
      showLoadingDialog();
      final authService = Authservice();
      final baseUrl = ApiEndpoints.normalizeUrl(urlCtrl.text);
      final db = dbCtrl.text.trim();
      final username = usernameController.text.trim();
      final password = passwordController.text.trim();

      try {
        final (isLoggedIn, sessionId, employeeId, employeeName, isRouteManagementInstalled) = await authService.login(
            baseUrl: baseUrl, db: db, username: username, password: password);
            
        if (!mounted) return;
        
        if (isLoggedIn && sessionId != null) {
          // Add or update the account with employee session details
          await AccountManager.instance.addOrUpdateAccount(
            serverUrl: baseUrl, 
            database: db, 
            username: username, 
            sessionId: sessionId,
            password: password,
            employeeId: employeeId,
            employeeName: employeeName,
            isRouteManagementInstalled: isRouteManagementInstalled,
          );

          if (employeeId != null) {
            GpsTrackingService.instance.setEmployeeSessionInfo(
              employeeId: employeeId,
              employeeName: employeeName ?? username,
            );
          }

          final accountId = Account.generateId(
            serverUrl: baseUrl, 
            database: db, 
            username: username
          );

          if (!mounted) return;
          final success = await AccountManager.instance.switchAccount(
            accountId, 
            context, 
            force: true, 
            skipValidation: true,
          );
          
          if (!mounted) return;
          navigator.pop(); // close loading dialog

          if (success) {
            // Trigger single initialization entry point safely in background
            unawaited(GpsTrackingService.instance.initialize());

            if (!mounted) return;
            if (widget.isAddingAccount) {
              navigator.pop(); // return to webview
            } else {
              navigator.pushReplacementNamed('/webview');
            }
          } else {
            scaffoldMessenger.showSnackBar(SnackBar(
                duration: const Duration(seconds: 3),
                backgroundColor: redColor,
                content: Text(
                  "Failed to activate session. Please check server URL.",
                  style: GoogleFonts.poppins(fontWeight: FontWeight.bold),
                )));
          }
        } else {
          navigator.pop(); // close loading dialog
          if (!mounted) return;
          scaffoldMessenger.showSnackBar(SnackBar(
              duration: const Duration(seconds: 3),
              backgroundColor: redColor,
              content: Text(
                "Invalid credentials, database, or server URL",
                style: GoogleFonts.poppins(fontWeight: FontWeight.bold),
              )));
        }
      } catch (e) {
        if (!mounted) return;
        navigator.pop(); // close loading dialog
        scaffoldMessenger.showSnackBar(
          SnackBar(
              duration: const Duration(seconds: 3),
              backgroundColor: redColor,
              content: Text(
                "Connection failed: ${e.toString()}",
                style: GoogleFonts.poppins(fontWeight: FontWeight.bold),
              )),
        );
      }
    }
  }

  void showLoadingDialog() {
    showGeneralDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (_, __, ___) => const SizedBox.shrink(),
      transitionBuilder: (_, animation, __, ___) {
        return Transform.scale(
          scale: 0.95 + (animation.value * 0.05),
          child: Opacity(
            opacity: animation.value,
            child: Center(
              child: Container(
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.1),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: const CircularProgressIndicator(),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // If we are pushed with arguments via named route, check isAddingAccount
    final args = ModalRoute.of(context)?.settings.arguments as Map?;
    final bool isAdding = widget.isAddingAccount || (args != null && args['isAddingAccount'] == true);

    return Scaffold(
      backgroundColor: secondaryColor,
      appBar: AppBar(
        backgroundColor: secondaryColor,
        elevation: 0,
        centerTitle: true,
        automaticallyImplyLeading: isAdding,
        iconTheme: IconThemeData(color: whiteColor),
        title: Text(
          isAdding ? "Add Account" : "Server Configuration",
          style: GoogleFonts.poppins(
            fontWeight: FontWeight.w600,
            fontSize: 18,
            color: whiteColor,
          ),
        ),
        toolbarHeight: 70,
      ),
      body: Form(
        key: _formKey,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 25),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(28),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 12,
                offset: const Offset(0, -3),
              )
            ],
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CustomTextField(
                        controller: urlCtrl,
                        hint: "Enter server URL",
                        icon: Icons.public,
                        upperText: "Server URL",
                      ),
                      vertGap(10),
                      CustomTextField(
                        controller: dbCtrl,
                        hint: "Company database",
                        icon: Symbols.database,
                        upperText: "Database",
                      ),
                      vertGap(10),
                      CustomTextField(
                        controller: usernameController,
                        hint: "Enter the username",
                        icon: Icons.person,
                        upperText: "Username",
                      ),
                      vertGap(10),
                      CustomTextField(
                        controller: passwordController,
                        hint: "Enter the password",
                        icon: Icons.security,
                        obscureText: true,
                        upperText: "Password",
                      ),
                      vertGap(10),
                      const SizedBox(height: 28),
                      SizedBox(
                        width: double.infinity,
                        height: 55,
                        child: ElevatedButton(
                          onPressed: saveConfig,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: secondaryColor,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: Text(
                            "Connect",
                            style: GoogleFonts.poppins(
                              color: whiteColor,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      )
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
