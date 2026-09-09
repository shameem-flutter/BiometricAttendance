import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:odoo_mobile/constants/color_constants.dart';
import 'package:odoo_mobile/services/account_manager.dart';

class AccountSwitcherSheet extends StatelessWidget {
  const AccountSwitcherSheet({super.key});

  static void show(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const AccountSwitcherSheet(),
    );
  }

  static Future<void> showLogoutDialog(
    BuildContext context, {
    String? accountId,
  }) async {
    final targetAccountId =
        accountId ?? AccountManager.instance.activeAccount?.id;
    if (targetAccountId == null) return;

    final targetAccount = AccountManager.instance.accounts
        .where((a) => a.id == targetAccountId)
        .firstOrNull;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          elevation: 0,
          backgroundColor: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.rectangle,
              borderRadius: BorderRadius.circular(20),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 10.0,
                  offset: Offset(0.0, 10.0),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.logout_rounded,
                    color: Colors.redAccent,
                    size: 32,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  "Log Out",
                  style: GoogleFonts.poppins(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  targetAccount != null
                      ? "Are you sure you want to log out of ${targetAccount.username}?"
                      : "Are you sure you want to log out?",
                  textAlign: TextAlign.center,
                  style: GoogleFonts.poppins(
                    fontSize: 14,
                    color: Colors.grey[600],
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: Text(
                          "Cancel",
                          style: GoogleFonts.poppins(
                            color: Colors.grey[700],
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () => Navigator.of(context).pop(true),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.redAccent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: Text(
                          "Log Out",
                          style: GoogleFonts.poppins(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );

    if (confirm == true && context.mounted) {
      if (accountId != null && Navigator.canPop(context)) {
        Navigator.pop(context);
      }
      await AccountManager.instance.removeAccount(targetAccountId, context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: ListenableBuilder(
        listenable: AccountManager.instance,
        builder: (context, _) {
          final accounts = AccountManager.instance.accounts;
          final activeAccountId = AccountManager.instance.activeAccount?.id;

          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag Handle
              Container(
                width: 40,
                height: 5,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(10),
                ),
              ),

              Text(
                "Switch Account",
                style: GoogleFonts.poppins(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: primaryColor,
                ),
              ),
              const SizedBox(height: 8),

              // Accounts List
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: accounts.length,
                  itemBuilder: (context, index) {
                    final account = accounts[index];
                    final isActive = account.id == activeAccountId;

                    return ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 0),
                      leading: CircleAvatar(
                        radius: 18,
                        backgroundColor:
                            isActive ? primaryColor : Colors.grey[300],
                        child: Text(
                          account.initials,
                          style: GoogleFonts.poppins(
                            color: isActive ? Colors.white : Colors.black54,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      title: Text(
                        account.username,
                        style: GoogleFonts.poppins(
                          fontWeight:
                              isActive ? FontWeight.bold : FontWeight.w500,
                          color: isActive ? primaryColor : Colors.black87,
                        ),
                      ),
                      subtitle: Text(
                        account.database,
                        style: GoogleFonts.poppins(
                          fontSize: 12,
                          color: Colors.grey[600],
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isActive)
                            Icon(Icons.check_circle, color: primaryColor),
                          IconButton(
                            icon: const Icon(Icons.logout,
                                color: Colors.redAccent, size: 20),
                            onPressed: () => showLogoutDialog(context, accountId: account.id),
                            tooltip: "Log Out Account",
                          )
                        ],
                      ),
                      onTap: () async {
                        if (!isActive) {
                          final nav = Navigator.of(context);
                          nav.pop();
                          final success = await AccountManager.instance
                              .switchAccount(account.id, context);
                          if (!success) {
                            nav.pushNamed("/login",
                                arguments: {'isAddingAccount': true});
                          }
                        }
                      },
                    );
                  },
                ),
              ),

              const Divider(),

              // Add Account Button
              ListTile(
                dense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 0),
                leading: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.grey, width: 1.5),
                  ),
                  child: const Icon(Icons.add, color: Colors.grey, size: 20),
                ),
                title: Text(
                  "Add Account",
                  style: GoogleFonts.poppins(
                    fontWeight: FontWeight.w500,
                    color: Colors.black87,
                  ),
                ),
                onTap: () {
                  Navigator.pop(context); // Close sheet
                  Navigator.pushNamed(context, "/login",
                      arguments: {'isAddingAccount': true});
                },
              ),
              const SizedBox(height: 12), // Bottom padding
            ],
          );
        },
      ),
    );
  }
}
