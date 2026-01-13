import 'package:flutter/material.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Web Table Ordering')),
      body: const Center(child: Text('Welcome to Web Table Ordering')),
    );
  }
}
