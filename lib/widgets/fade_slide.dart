import 'dart:async';

import 'package:flutter/material.dart';

class FadeSlide extends StatefulWidget {
  const FadeSlide({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    /// When false, skip the entrance animation (lists that rebuild often).
    this.animate = true,
  });

  final Widget child;
  final Duration delay;
  final bool animate;

  @override
  State<FadeSlide> createState() => _FadeSlideState();
}

class _FadeSlideState extends State<FadeSlide>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  Animation<double>? _opacity;
  Animation<Offset>? _offset;
  Timer? _delayTimer;

  @override
  void initState() {
    super.initState();
    if (!widget.animate) {
      return;
    }
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _controller = controller;
    _opacity = CurvedAnimation(parent: controller, curve: Curves.easeOut);
    _offset = Tween<Offset>(
      begin: const Offset(0, 0.05),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: controller, curve: Curves.easeOut));
    if (widget.delay == Duration.zero) {
      controller.forward();
    } else {
      _delayTimer = Timer(widget.delay, () {
        if (mounted) {
          controller.forward();
        }
      });
    }
  }

  @override
  void dispose() {
    _delayTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final opacity = _opacity;
    final offset = _offset;
    if (controller == null || opacity == null || offset == null) {
      return widget.child;
    }
    return FadeTransition(
      opacity: opacity,
      child: SlideTransition(position: offset, child: widget.child),
    );
  }
}
