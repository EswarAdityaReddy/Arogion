import 'package:flutter/material.dart';

class PrimaryButton extends StatelessWidget {
  final String text;
  final VoidCallback? onPressed;
  final bool isLoading;
  final Color? backgroundColor;
  final Color? textColor;
  final double? width;
  final double height;
  final double borderRadius;

  const PrimaryButton({
    super.key,
    required this.text,
    this.onPressed,
    this.isLoading = false,
    this.backgroundColor,
    this.textColor,
    this.width,
    this.height = 56,
    this.borderRadius = 30,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width ?? double.infinity,
      height: height,
      child: ElevatedButton(
        onPressed: isLoading ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: backgroundColor ?? const Color(0xFF1A237E),
          foregroundColor: textColor ?? Colors.white,
          disabledBackgroundColor: const Color(0xFF1A237E).withAlpha(150),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(borderRadius),
          ),
          elevation: 0,
        ),
        child: isLoading
            ? Text(
                'Please wait...',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: textColor ?? Colors.white,
                ),
              )
            : Text(
                text,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: textColor ?? Colors.white,
                ),
              ),
      ),
    );
  }
}

class SocialButton extends StatelessWidget {
  final String iconPath;
  final String? text;
  final VoidCallback? onPressed;
  final bool isLoading;

  const SocialButton({
    super.key,
    required this.iconPath,
    this.text,
    this.onPressed,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 88,
      height: 60,
      child: OutlinedButton(
        onPressed: isLoading ? null : onPressed,
        style: OutlinedButton.styleFrom(
          backgroundColor: Colors.white,
          side: BorderSide(color: Colors.grey[300]!, width: 1),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: isLoading
            ? const Icon(
                Icons.hourglass_top_rounded,
                color: Color(0xFF2C3E50),
                size: 22,
              )
            : _buildIcon(),
      ),
    );
  }

  Widget _buildIcon() {
    if (iconPath == 'google') {
      return Image.network(
        'https://www.google.com/favicon.ico',
        width: 24,
        height: 24,
        errorBuilder: (context, error, stackTrace) {
          return const Icon(Icons.g_mobiledata, size: 28);
        },
      );
    } else if (iconPath == 'facebook') {
      return const Icon(Icons.facebook, color: Color(0xFF1877F2), size: 28);
    }
    return const Icon(Icons.error);
  }
}
