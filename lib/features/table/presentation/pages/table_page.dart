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
          if (state is TableLoaded) {
            context.read<CartBloc>().add(LoadActiveOrder(state.table.tableId));
          } else if (state is TableError) {
            context.go('/404');
          }
        },
        child: Scaffold(
          body: Stack(
            children: [
              Container(
                decoration: const BoxDecoration(
                  image: DecorationImage(
                    image: AssetImage("assets/images/nyx.jpg"),
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
                              'assets/images/nyx_logo.jpg',
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
                                      "Welcome to NYX Vikings",
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                        fontFamily: 'Marous',
                                        foreground: Paint()
                                          ..style = PaintingStyle.stroke
                                          ..strokeWidth = 1
                                          ..color = Colors
                                              .black, // Color of the stroke
                                      ),
                                    ),
                                    // Solid Text Layer
                                    Text(
                                      "Welcome to NYX Vikings",
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ],
                                ),
                                Stack(
                                  children: [
                                    // Stroke Layer
                                    Text(
                                      "A place where gastronomy meets grandeur.",
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
                                      "A place where gastronomy meets grandeur.",
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w100,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ],
                                ),
                                if (table.description.isNotEmpty) ...[
                                  const SizedBox(height: 10),
                                  Stack(
                                    children: [
                                      // Stroke Layer
                                      Text(
                                        "Table: ${table.description}",
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
                                        "Table: ${table.description}",
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
                              ],
                            ),
                          ),
                          const SizedBox(height: 20),
                          SizedBox(
                            width: 200,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: Colors.black,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(15),
                                ),
                              ),
                              onPressed: () =>
                                  context.go('/table/${table.uuid}/menu'),
                              child: const Text(
                                'Start Ordering',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Colors.black,
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
                                backgroundColor: Colors.white,
                                foregroundColor: Colors.black,
                                side: const BorderSide(
                                  color: Colors.white,
                                  width: 1,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(15),
                                ),
                              ),
                              onPressed: () => context.go(
                                '/table/${table.uuid}/order_summary',
                              ),
                              child: const Text(
                                'View Orders',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Colors.black,
                                  fontFamily: 'SolemnSojourn',
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),

                          SizedBox(
                            width: 200,
                            child: BlocBuilder<CartBloc, CartState>(
                              builder: (context, cartState) {
                                final hasActiveOrders =
                                    cartState.activeOrders.isNotEmpty;
                                return ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.white,
                                    foregroundColor: Colors.black,
                                    side: const BorderSide(
                                      color: Colors.white,
                                      width: 1,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(15),
                                    ),
                                  ),
                                  onPressed: hasActiveOrders
                                      ? () {
                                          showDialog(
                                            context: context,
                                            builder: (dialogContext) {
                                              return Dialog(
                                                backgroundColor: const Color(
                                                  0xFF121212,
                                                ),
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(24),
                                                  side: BorderSide(
                                                    color: Colors.white
                                                        .withValues(alpha: 0.1),
                                                    width: 1.5,
                                                  ),
                                                ),
                                                child: ConstrainedBox(
                                                  constraints:
                                                      const BoxConstraints(
                                                        maxWidth: 400,
                                                      ),
                                                  child: Padding(
                                                    padding:
                                                        const EdgeInsets.all(
                                                          24.0,
                                                        ),
                                                    child: Column(
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .stretch,
                                                      children: [
                                                        Row(
                                                          children: [
                                                            Container(
                                                              padding:
                                                                  const EdgeInsets.all(
                                                                    8,
                                                                  ),
                                                              decoration: BoxDecoration(
                                                                color:
                                                                    const Color.fromARGB(
                                                                      255,
                                                                      235,
                                                                      209,
                                                                      16,
                                                                    ).withValues(
                                                                      alpha:
                                                                          0.1,
                                                                    ),
                                                                shape: BoxShape
                                                                    .circle,
                                                              ),
                                                              child: const Icon(
                                                                Icons
                                                                    .receipt_long,
                                                                color:
                                                                    Color.fromARGB(
                                                                      255,
                                                                      235,
                                                                      209,
                                                                      16,
                                                                    ),
                                                                size: 24,
                                                              ),
                                                            ),
                                                            const SizedBox(
                                                              width: 12,
                                                            ),
                                                            const Text(
                                                              'Request Bill',
                                                              style: TextStyle(
                                                                color: Colors
                                                                    .white,
                                                                fontSize: 20,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .bold,
                                                                fontFamily:
                                                                    'serif',
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                        const SizedBox(
                                                          height: 16,
                                                        ),
                                                        Text(
                                                          'Are you sure you want to request the bill? This will lock the menu from further ordering.',
                                                          style: TextStyle(
                                                            color: Colors.white
                                                                .withValues(
                                                                  alpha: 0.7,
                                                                ),
                                                            fontSize: 14,
                                                            height: 1.5,
                                                          ),
                                                        ),
                                                        const SizedBox(
                                                          height: 24,
                                                        ),
                                                        Row(
                                                          mainAxisAlignment:
                                                              MainAxisAlignment
                                                                  .end,
                                                          children: [
                                                            TextButton(
                                                              onPressed: () =>
                                                                  Navigator.of(
                                                                    dialogContext,
                                                                  ).pop(),
                                                              style: TextButton.styleFrom(
                                                                foregroundColor:
                                                                    Colors.white
                                                                        .withValues(
                                                                          alpha:
                                                                              0.6,
                                                                        ),
                                                              ),
                                                              child: const Text(
                                                                'Cancel',
                                                                style: TextStyle(
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .bold,
                                                                ),
                                                              ),
                                                            ),
                                                            const SizedBox(
                                                              width: 12,
                                                            ),
                                                            ElevatedButton(
                                                              style: ElevatedButton.styleFrom(
                                                                backgroundColor:
                                                                    const Color.fromARGB(
                                                                      255,
                                                                      235,
                                                                      209,
                                                                      16,
                                                                    ),
                                                                foregroundColor:
                                                                    Colors
                                                                        .black,
                                                                elevation: 0,
                                                                padding:
                                                                    const EdgeInsets.symmetric(
                                                                      horizontal:
                                                                          24,
                                                                      vertical:
                                                                          12,
                                                                    ),
                                                                shape: RoundedRectangleBorder(
                                                                  borderRadius:
                                                                      BorderRadius.circular(
                                                                        12,
                                                                      ),
                                                                ),
                                                              ),
                                                              onPressed: () {
                                                                Navigator.of(
                                                                  dialogContext,
                                                                ).pop();
                                                                context
                                                                    .read<
                                                                      CartBloc
                                                                    >()
                                                                    .add(
                                                                      RequestBill(
                                                                        table
                                                                            .tableId,
                                                                      ),
                                                                    );
                                                                ScaffoldMessenger.of(
                                                                  context,
                                                                ).showSnackBar(
                                                                  const SnackBar(
                                                                    content: Text(
                                                                      'Bill requested successfully',
                                                                    ),
                                                                  ),
                                                                );
                                                              },
                                                              child: const Text(
                                                                'Confirm',
                                                                style: TextStyle(
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .bold,
                                                                ),
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              );
                                            },
                                          );
                                        }
                                      : null,
                                  child: const Text(
                                    'Request bill',
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: Colors
                                          .black, // Note: This might look white on inactive button, but ElevatedButton handles it usually.
                                      fontFamily: 'SolemnSojourn',
                                    ),
                                  ),
                                );
                              },
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
