import 'package:flutter/material.dart';

class HomePage extends StatelessWidget {
  final String? tableUuid;
  const HomePage({super.key, this.tableUuid});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Web Table Ordering')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Welcome to Web Table Ordering'),
            if (tableUuid != null) Text('Table UUID: $tableUuid'),
          ],
        ),
      ),
    );
  }
}
