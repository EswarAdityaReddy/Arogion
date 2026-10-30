import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

class MedicalLoader extends StatelessWidget {
  const MedicalLoader({super.key, this.size = 120});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Lottie.asset(
        'assets/animations/medical_loader.json',
        repeat: true,
        animate: true,
        frameRate: FrameRate.max,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) {
          return Center(
            child: SizedBox(
              width: size * 0.24,
              height: size * 0.24,
              child: const CircularProgressIndicator(
                strokeWidth: 2.4,
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF2E86DE)),
              ),
            ),
          );
        },
      ),
    );
  }
}
