import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import '../bloc/table_bloc.dart';
import '../../../orders/presentation/bloc/cart_bloc.dart';

class TablePage extends StatelessWidget {
  const TablePage({super.key});

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
      ),
      child: BlocListener<TableBloc, TableState>(
        listener: (context, state) {
          if (state is TableError) {
            context.go('/404');
          }
        },
        child: Scaffold(
          body: Stack(
            children: [
              Container(
                decoration: const BoxDecoration(
                  image: DecorationImage(
                    image: AssetImage("assets/images/bg_image.jpg"),
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              Center(
                child: BlocBuilder<TableBloc, TableState>(
                  builder: (context, state) {
                    if (state is TableLoading) {
                      return const CircularProgressIndicator();
                    } else if (state is TableLoaded) {
                      final table = state.table;
                      return Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          ClipOval(
                            child: Image.asset(
                              'assets/images/logo.jpg',
                              fit: BoxFit.contain,
                              width: 150,
                              height: 150,
                            ),
                          ),
                          const SizedBox(height: 20),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(vertical: 15),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.5),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Stack(
                                  children: [
                                    // Stroke Layer
                                    Text(
                                      "Welcome to Chickey's Inasal",
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                        fontFamily: 'Marous',
                                        foreground: Paint()
                                          ..style = PaintingStyle.stroke
                                          ..strokeWidth = 1
                                          ..color = Colors.black, // Color of the stroke
                                      ),
                                    ),
                                    // Solid Text Layer
                                    Text(
                                      "Welcome to Chickey's Inasal",
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                        fontFamily: 'Marous',
                                        color: Colors.white,
                                      ),
                                    ),
                                  ],
                                ),
                                Stack(
                                  children: [
                                    // Stroke Layer
                                    Text(
                                      "Taste the best filipino chicken inasal",
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w100,
                                        foreground: Paint()
                                          ..style = PaintingStyle.stroke
                                          ..strokeWidth = 1
                                          ..color = Colors.black,
                                      ),
                                    ),
                                    // Solid Text Layer
                                    Text(
                                      "Taste the best filipino chicken inasal",
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w100,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 20),
                          SizedBox(
                            width: 200,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Color(0xfff25125),
                                foregroundColor: Colors.white,
                                side: const BorderSide(color: Colors.white, width: 1),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(15),
                                ),
                              ),
                              onPressed: () => context.go('/table/${table.uuid}/menu'),
                              child: const Text(
                                'Start Ordering',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Colors.white,
                                  fontFamily: 'SolemnSojourn',
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          SizedBox(
                            width: 200,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Color(0xfff25125),
                                foregroundColor: Colors.white,
                                side: const BorderSide(color: Colors.white, width: 1),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(15),
                                ),
                              ),
                              onPressed: () => context.go('/table/${table.uuid}/order_summary'),
                              child: const Text(
                                'View Orders',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Colors.white,
                                  fontFamily: 'SolemnSojourn',
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),

                          SizedBox(
                            width: 200,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Color(0xfff25125),
                                foregroundColor: Colors.white,
                                side: const BorderSide(color: Colors.white, width: 1),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(15),
                                ),
                              ),
                              onPressed: () {
                                showDialog(
                                  context: context,
                                  builder: (dialogContext) {
                                    return AlertDialog(
                                      title: const Text('Request Bill'),
                                      content: const Text(
                                        'Are you sure you want to request the bill?\nThis will lock the menu from further ordering.',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.of(dialogContext).pop(),
                                          child: const Text('Cancel'),
                                        ),
                                        ElevatedButton(
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: const Color(0xfff25125),
                                            foregroundColor: Colors.white,
                                          ),
                                          onPressed: () {
                                            Navigator.of(dialogContext).pop();
                                            context.read<CartBloc>().add(RequestBill(table.tableId));
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              const SnackBar(content: Text('Bill requested successfully')),
                                            );
                                          },
                                          child: const Text('Confirm'),
                                        ),
                                      ],
                                    );
                                  },
                                );
                              },
                              child: const Text(
                                'Request bill',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Colors.white,
                                  fontFamily: 'SolemnSojourn',
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    } else if (state is TableError) {
                      // This will be handled by the listener, but we can show a fallback here
                      return Text('Error: ${state.message}');
                    }
                    return const Text('Loading table info...');
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
