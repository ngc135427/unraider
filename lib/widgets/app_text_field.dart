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
    this.textInputAction,
    this.onChanged,
    this.onFieldSubmitted,
    this.autofillHints,
    this.enabled = true,
    this.keyboardType,
  });

  final String label;
  final TextEditingController controller;
  final String hint;
  final IconData? icon;
  final bool obscureText;
  final FocusNode? focusNode;
  final String? Function(String?)? validator;
  final Widget? suffixIcon;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onFieldSubmitted;
  final Iterable<String>? autofillHints;
  final bool enabled;
  final TextInputType? keyboardType;

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
          enabled: enabled,
          validator: validator,
          textInputAction: textInputAction,
          onChanged: onChanged,
          onFieldSubmitted: onFieldSubmitted,
          autofillHints: autofillHints,
          keyboardType: keyboardType,
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
