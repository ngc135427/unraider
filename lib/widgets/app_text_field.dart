import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    required this.label,
    required this.controller,
    required this.hint,
    this.icon,
    this.obscureText = false,
    this.focusNode,
    this.validator,
    this.suffixIcon,
  });

  final String label;
  final TextEditingController controller;
  final String hint;
  final IconData? icon;
  final bool obscureText;
  final FocusNode? focusNode;
  final String? Function(String?)? validator;
  final Widget? suffixIcon;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: AppTheme.textMedium,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          focusNode: focusNode,
          obscureText: obscureText,
          validator: validator,
          decoration: InputDecoration(
            hintText: hint,
            suffixIcon: suffixIcon ??
                (icon == null
                    ? null
                    : Icon(icon, color: const Color(0xFFA0A8B9))),
          ),
        ),
      ],
    );
  }
}
