import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class PhoneFrame extends StatelessWidget {
  const PhoneFrame({
    super.key,
    required this.child,
    this.maxContentWidth,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final double? maxContentWidth;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final content = maxContentWidth == null
        ? child
        : Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxContentWidth!),
              child: SizedBox.expand(child: child),
            ),
          );

    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: AppTheme.brandGradient,
        ),
        child: SafeArea(
          child: Padding(
            padding: padding,
            child: SizedBox.expand(
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}
