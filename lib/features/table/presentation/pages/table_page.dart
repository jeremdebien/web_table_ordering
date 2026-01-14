import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import '../cubit/table_context_cubit.dart';

class TablePage extends StatelessWidget {
  const TablePage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocListener<TableContextCubit, TableContextState>(
      listener: (context, state) {
        if (state is TableContextError) {
          context.go('/404');
        }
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Table Details')),
        body: Center(
          child: BlocBuilder<TableContextCubit, TableContextState>(
            builder: (context, state) {
              if (state is TableContextLoading) {
                return const CircularProgressIndicator();
              } else if (state is TableContextLoaded) {
                final table = state.table;
                return Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Table: ${table.description}',
                      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 10),
                    Text('ID: ${table.tableId}'),
                    if (table.uuid != null) Text('UUID: ${table.uuid}'),
                    Text('Status: ${table.isActive ? "Active" : "Inactive"}'),

                    const SizedBox(height: 20),
                    // Here we can eventually add the menu or order summary
                    const Text('Menu and features will be loaded here.'),
                  ],
                );
              } else if (state is TableContextError) {
                // This will be handled by the listener, but we can show a fallback here
                return Text('Error: ${state.message}');
              }
              return const Text('Loading table info...');
            },
          ),
        ),
      ),
    );
  }
}
