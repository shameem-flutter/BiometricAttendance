import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:odoo_mobile/constants/color_constants.dart';
import 'package:odoo_mobile/constants/gap_func.dart';

class CustomTextField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData? icon;
  final String? Function(String?)? validator;
  final bool obscureText;
  final TextInputType keyboardType;
  final String? upperText;

  const CustomTextField({
    super.key,
    required this.controller,
    required this.hint,
    this.icon,
    this.upperText,
    this.validator,
    this.obscureText = false,
    this.keyboardType = TextInputType.text,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (upperText != null) ...[
          Text(
            upperText!,
            style: GoogleFonts.poppins(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: secondaryColor),
          ),
          vertGap(5)
        ],
        TextFormField(
          controller: controller,
          validator: (value) {
            if (value == null || value.trim().isEmpty) {
              return "this field is required";
            }
            return null;
          },
          obscureText: obscureText,
          keyboardType: keyboardType,
          style: TextStyle(color: secondaryColor),
          decoration: InputDecoration(
            prefixIcon: Icon(icon, color: secondaryColor),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
            filled: true,
            fillColor: secondaryColor.withValues(alpha: 0.12),
            hintText: hint,
            hintStyle: GoogleFonts.poppins(
              color: secondaryColor.withValues(alpha: 0.6),
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
          ),
        )
      ],
    );
  }
}
