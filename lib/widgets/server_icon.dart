import 'package:flutter/material.dart';

enum ServerIconVariant { defaultIcon, tower, orbit, diamond }

class ServerIconView extends StatelessWidget {
  const ServerIconView({
    super.key,
    required this.variant,
    this.size = 120,
  });

  final ServerIconVariant variant;
  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _ServerIconPainter(variant),
    );
  }
}

class _ServerIconPainter extends CustomPainter {
  const _ServerIconPainter(this.variant);

  final ServerIconVariant variant;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final radius = Radius.circular(size.width * 0.08);
    final paint = Paint()..style = PaintingStyle.fill;

    switch (variant) {
      case ServerIconVariant.defaultIcon:
        paint.color = Colors.black;
        canvas.drawRRect(RRect.fromRectAndRadius(rect, radius), paint);
        paint.color = Colors.white;
        for (final y in [0.25, 0.42, 0.59]) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(
                size.width * 0.17,
                size.height * y,
                size.width * 0.66,
                size.height * 0.13,
              ),
              Radius.circular(size.width * 0.02),
            ),
            paint,
          );
        }
        canvas.drawCircle(
          Offset(size.width * 0.13, size.height * 0.13),
          size.width * 0.04,
          paint,
        );
        break;
      case ServerIconVariant.tower:
        paint.color = const Color(0xFF2C3E50);
        canvas.drawRRect(RRect.fromRectAndRadius(rect, radius), paint);
        paint.color = const Color(0xFF34495E);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              size.width * 0.22,
              size.height * 0.17,
              size.width * 0.56,
              size.height * 0.66,
            ),
            Radius.circular(size.width * 0.04),
          ),
          paint,
        );
        for (final dot in [
          (0.29, const Color(0xFF3498DB)),
          (0.46, const Color(0xFF2ECC71)),
          (0.63, const Color(0xFFE74C3C)),
        ]) {
          paint.color = dot.$2;
          canvas.drawCircle(
            Offset(size.width * 0.5, size.height * dot.$1),
            size.width * 0.04,
            paint,
          );
        }
        paint.color = const Color(0xFFECF0F1);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              size.width * 0.34,
              size.height * 0.79,
              size.width * 0.32,
              size.height * 0.04,
            ),
            Radius.circular(size.width * 0.02),
          ),
          paint,
        );
        break;
      case ServerIconVariant.orbit:
        paint.color = const Color(0xFF8E44AD);
        canvas.drawRRect(RRect.fromRectAndRadius(rect, radius), paint);
        paint.color = const Color(0xFF9B59B6);
        canvas.drawCircle(rect.center, size.width * 0.33, paint);
        final stroke = Paint()
          ..color = const Color(0xFFECF0F1)
          ..strokeWidth = size.width * 0.04
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(
          Offset(size.width * 0.5, size.height * 0.25),
          Offset(size.width * 0.5, size.height * 0.75),
          stroke,
        );
        canvas.drawLine(
          Offset(size.width * 0.25, size.height * 0.5),
          Offset(size.width * 0.75, size.height * 0.5),
          stroke,
        );
        paint.color = const Color(0xFFECF0F1);
        canvas.drawCircle(rect.center, size.width * 0.08, paint);
        break;
      case ServerIconVariant.diamond:
        paint.color = const Color(0xFF16A085);
        canvas.drawRRect(RRect.fromRectAndRadius(rect, radius), paint);
        final path = Path()
          ..moveTo(size.width * 0.5, size.height * 0.17)
          ..lineTo(size.width * 0.75, size.height * 0.5)
          ..lineTo(size.width * 0.5, size.height * 0.83)
          ..lineTo(size.width * 0.25, size.height * 0.5)
          ..close();
        paint.color = const Color(0xFF1ABC9C);
        canvas.drawPath(path, paint);
        paint.color = const Color(0xFFECF0F1);
        canvas.drawCircle(rect.center, size.width * 0.13, paint);
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _ServerIconPainter oldDelegate) {
    return oldDelegate.variant != variant;
  }
}
