import 'package:flutter/material.dart';
import '../utils/splash_dismisser.dart';

class NotFoundPage extends StatelessWidget {
  const NotFoundPage({super.key});

  @override
  Widget build(BuildContext context) {
    // Wrapped so a failed QR resolve (or any cold-load 404) lifts the HTML
    // loading splash instead of leaving it stuck over the page.
    return SplashDismisser(
      child: Scaffold(
        body: Center(
          child: Image.asset(
            'assets/images/404.jpg',
            width: MediaQuery.of(context).size.width * 0.8,
            height: MediaQuery.of(context).size.height * 0.8,
          ),
        ),
      ),
    );
  }
}
