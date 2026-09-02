import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:web_table_ordering/features/menu/data/models/instruction_group_model.dart';
import 'package:web_table_ordering/features/orders/data/models/sales_order_item_model.dart';
import 'package:web_table_ordering/features/orders/presentation/bloc/cart_bloc.dart';
import 'special_instructions_form.dart';

/// Bottom sheet shown when a user taps an item card to customize and add it to the cart.
/// Features adaptive hero height, hold-to-peek image preview, quick note chips, and collapsible sections.
class AddItemBottomSheet extends StatefulWidget {
  final dynamic item;
  final Future<List<InstructionGroup>> instructionsFuture;

  const AddItemBottomSheet({
    super.key,
    required this.item,
    required this.instructionsFuture,
  });

  @override
  State<AddItemBottomSheet> createState() => _AddItemBottomSheetState();
}

class _AddItemBottomSheetState extends State<AddItemBottomSheet> {
  int _quantity = 1;
  bool _isValid = true;
  String? _instructionsJson;
  final TextEditingController _noteController = TextEditingController();
  bool _isNoteExpanded = true;
  OverlayEntry? _peekOverlayEntry;

  // Instruction groups are loaded inside the sheet so it can open instantly.
  List<InstructionGroup> _groups = const [];
  bool _loadingInstructions = true;

  @override
  void initState() {
    super.initState();
    // Can't submit until instructions have loaded (a required group may exist).
    _isValid = false;
    _noteController.addListener(() {
      setState(() {});
    });
    _loadInstructions();
  }

  Future<void> _loadInstructions() async {
    final groups = await widget.instructionsFuture;
    if (!mounted) return;
    setState(() {
      _groups = groups;
      _loadingInstructions = false;
      // If there are no instruction groups, the form is always valid.
      _isValid = groups.isEmpty;
      // For items with many instruction groups, default note section to
      // collapsed to keep view clean.
      _isNoteExpanded = groups.length <= 2;
    });
  }

  @override
  void dispose() {
    _hidePeekOverlay();
    _noteController.dispose();
    super.dispose();
  }

  void _onInstructionsChanged(bool isValid, String? json) {
    setState(() {
      _isValid = isValid;
      _instructionsJson = json;
    });
  }

  void _addToCart() {
    HapticFeedback.mediumImpact();
    final noteText = _noteController.text.trim();
    final note = noteText.isNotEmpty ? noteText : null;

    Navigator.pop(context);
    context.read<CartBloc>().add(
      AddToCart(
        SalesOrderItemModel(
          itemBarcode: widget.item.barcode,
          itemName: widget.item.name,
          quantity: _quantity,
          amount: widget.item.price,
          originalQuantity: 0,
          specialInstructions: _instructionsJson,
          note: note,
        ),
      ),
    );
  }

  // Persistent modal dialog with InteractiveViewer zoom
  void _openFullScreenImage(String imageUrl) {
    HapticFeedback.lightImpact();
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.88),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(12),
        child: Stack(
          alignment: Alignment.center,
          children: [
            InteractiveViewer(
              minScale: 0.8,
              maxScale: 3.5,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.network(
                  imageUrl,
                  fit: BoxFit.contain,
                  errorBuilder: (ctx, error, stackTrace) => const Icon(
                    Icons.broken_image,
                    color: Colors.white,
                    size: 64,
                  ),
                ),
              ),
            ),
            Positioned(
              top: 10,
              right: 10,
              child: CircleAvatar(
                backgroundColor: Colors.black.withValues(alpha: 0.6),
                child: IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Hold-to-peek overlay triggered on long press
  void _showPeekOverlay(String imageUrl) {
    if (_peekOverlayEntry != null) return;
    HapticFeedback.heavyImpact();

    _peekOverlayEntry = OverlayEntry(
      builder: (context) => _PeekImageOverlay(
        imageUrl: imageUrl,
        itemName: widget.item.name,
      ),
    );

    Overlay.of(context).insert(_peekOverlayEntry!);
  }

  void _hidePeekOverlay() {
    if (_peekOverlayEntry != null) {
      HapticFeedback.lightImpact();
      _peekOverlayEntry?.remove();
      _peekOverlayEntry = null;
    }
  }

  String _formatPrice(double price) {
    if (price % 1 == 0) {
      return price.toInt().toString();
    }
    return price.toStringAsFixed(2);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final totalPrice = item.price * _quantity;
    final hasImage = item.displayImage != null && item.displayImage!.toString().isNotEmpty;
    // While loading, reserve the compact hero so layout doesn't jump once the
    // instructions area appears; treat "loading" like "has instructions".
    final hasSpecialInstructions = _groups.isNotEmpty;
    final showInstructionsSection = _loadingInstructions || hasSpecialInstructions;

    // Adaptive hero image height:
    // When there are no special instructions, expand image to 350px for an appealing visual spotlight.
    // When there are special instructions, use a 250px hero height to keep options visible above the fold.
    final double heroImageHeight = showInstructionsSection ? 250.0 : 350.0;

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.92,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Scrollable Content (begins right at the top rounded edge of the bottom sheet)
              Expanded(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Hero Image with adaptive height & overlaid floating controls
                      Stack(
                        children: [
                          GestureDetector(
                            onTap: hasImage ? () => _openFullScreenImage(item.displayImage!) : null,
                            onLongPressStart: hasImage ? (_) => _showPeekOverlay(item.displayImage!) : null,
                            onLongPressEnd: hasImage ? (_) => _hidePeekOverlay() : null,
                            onLongPressCancel: hasImage ? () => _hidePeekOverlay() : null,
                            onLongPressUp: hasImage ? () => _hidePeekOverlay() : null,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 300),
                              curve: Curves.easeInOut,
                              height: heroImageHeight,
                              width: double.infinity,
                              decoration: BoxDecoration(
                                color: Colors.grey.shade100,
                              ),
                              child: hasImage
                                  ? Image.network(
                                      item.displayImage!,
                                      fit: BoxFit.cover,
                                      errorBuilder: (ctx, err, stack) => _buildPlaceholder(),
                                    )
                                  : _buildPlaceholder(),
                            ),
                          ),

                          // Top & Bottom gradient overlay on image for contrast
                          Positioned.fill(
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.black.withValues(alpha: 0.45),
                                      Colors.transparent,
                                      Colors.black.withValues(alpha: 0.5),
                                    ],
                                    stops: const [0.0, 0.45, 1.0],
                                  ),
                                ),
                              ),
                            ),
                          ),

                          // Drag Handle Pill (Overlaid directly at the top of the image)
                          Positioned(
                            top: 10,
                            left: 0,
                            right: 0,
                            child: Center(
                              child: Container(
                                width: 44,
                                height: 5,
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.85),
                                  borderRadius: BorderRadius.circular(3),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.25),
                                      blurRadius: 4,
                                      offset: const Offset(0, 1),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),

                          // Glassmorphic Close button
                          Positioned(
                            top: 14,
                            right: 14,
                            child: ClipOval(
                              child: BackdropFilter(
                                filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                                child: Material(
                                  color: Colors.black.withValues(alpha: 0.38),
                                  shape: const CircleBorder(),
                                  child: InkWell(
                                    onTap: () => Navigator.pop(context),
                                    customBorder: const CircleBorder(),
                                    child: const Padding(
                                      padding: EdgeInsets.all(8.0),
                                      child: Icon(
                                        Icons.close_rounded,
                                        color: Colors.white,
                                        size: 20,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),

                          // Hold to preview / Tap to expand badge
                          if (hasImage)
                            Positioned(
                              bottom: 12,
                              right: 14,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(20),
                                child: BackdropFilter(
                                  filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                    color: Colors.black.withValues(alpha: 0.4),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: const [
                                        Icon(Icons.touch_app_rounded, color: Colors.white, size: 14),
                                        SizedBox(width: 4),
                                        Text(
                                          'Hold to preview',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),

                      // Details Container
                      Padding(
                        padding: const EdgeInsets.all(20.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Item title & price row
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Text(
                                    item.name,
                                    style: const TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: -0.5,
                                      color: Color(0xFF1A1A1A),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 7,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1A1A1A),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Text(
                                    '₱${_formatPrice(item.price.toDouble())}',
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w800,
                                      color: Color(0xFFCEB38C),
                                    ),
                                  ),
                                ),
                              ],
                            ),

                            // Description
                            if (item.description != null && item.description!.toString().isNotEmpty) ...[
                              const SizedBox(height: 10),
                              Text(
                                item.description!,
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 1.45,
                                  color: Colors.grey.shade600,
                                ),
                              ),
                            ],

                            const SizedBox(height: 20),

                            // 1. Predefined Special Instructions (rendered first)
                            if (showInstructionsSection) ...[
                              Row(
                                children: [
                                  const Icon(
                                    Icons.tune_rounded,
                                    size: 18,
                                    color: Color(0xFF1A1A1A),
                                  ),
                                  const SizedBox(width: 6),
                                  const Text(
                                    'Special Instructions',
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF1A1A1A),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              if (_loadingInstructions)
                                const _InstructionsLoadingPlaceholder()
                              else
                                SpecialInstructionsForm(
                                  groups: _groups,
                                  onChanged: _onInstructionsChanged,
                                ),
                              const SizedBox(height: 16),
                            ],

                            // 2. Free-text Kitchen Note (rendered after special instructions)
                            _buildKitchenNoteSection(),

                            const SizedBox(height: 20),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Sticky Bottom Bar
              _buildBottomActionBar(item, totalPrice),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.restaurant_rounded,
            size: 52,
            color: Colors.grey.shade400,
          ),
          const SizedBox(height: 8),
          Text(
            'Handcrafted Dish',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade400,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildKitchenNoteSection() {
    final noteText = _noteController.text.trim();
    final hasText = noteText.isNotEmpty;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFA),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: const Color(0xFFE5E7EB),
          width: 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Collapsible Header Row
          InkWell(
            onTap: () {
              setState(() {
                _isNoteExpanded = !_isNoteExpanded;
              });
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  const Icon(
                    Icons.edit_note_rounded,
                    size: 22,
                    color: Color(0xFFC5A880),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Text(
                              'Kitchen Note',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF1A1A1A),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.grey.shade200,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                'OPTIONAL',
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.grey.shade700,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (!_isNoteExpanded && hasText)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              noteText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF8C6D46),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Icon(
                    _isNoteExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                    color: Colors.grey.shade600,
                  ),
                ],
              ),
            ),
          ),

          // Expandable Body
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 200),
            crossFadeState: _isNoteExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Padding(
              padding: const EdgeInsets.only(left: 16, right: 16, bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Special requests, allergies, or cooking preferences for the kitchen.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Free-text TextField
                  TextField(
                    controller: _noteController,
                    minLines: 2,
                    maxLines: 4,
                    textCapitalization: TextCapitalization.sentences,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF1A1A1A),
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: Colors.white,
                      hintText: 'e.g. Less ice, no onions, extra spicy, sauce on the side...',
                      hintStyle: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade400,
                      ),
                      suffixIcon: hasText
                          ? IconButton(
                              icon: const Icon(Icons.clear_rounded, size: 16),
                              color: Colors.grey.shade600,
                              onPressed: () {
                                _noteController.clear();
                                HapticFeedback.lightImpact();
                              },
                            )
                          : null,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                          color: Color(0xFF1A1A1A),
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomActionBar(dynamic item, double totalPrice) {
    return Container(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 14,
        bottom: 14 + MediaQuery.of(context).padding.bottom,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 16,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: Row(
        children: [
          // Quantity selector stepper
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(16),
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: 6,
              vertical: 6,
            ),
            child: Row(
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: _quantity > 1
                      ? () {
                          HapticFeedback.selectionClick();
                          setState(() => _quantity--);
                        }
                      : null,
                  child: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: _quantity > 1 ? Colors.white : Colors.white.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: _quantity > 1
                          ? [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.04),
                                blurRadius: 4,
                                offset: const Offset(0, 2),
                              ),
                            ]
                          : null,
                    ),
                    child: Icon(
                      Icons.remove_rounded,
                      size: 18,
                      color: _quantity > 1 ? Colors.black87 : Colors.grey.shade400,
                    ),
                  ),
                ),
                Container(
                  constraints: const BoxConstraints(minWidth: 36),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text(
                    '$_quantity',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1A1A1A),
                    ),
                  ),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() => _quantity++);
                  },
                  child: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A1A),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.15),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.add_rounded,
                      size: 18,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),

          // Add to order button
          Expanded(
            child: SizedBox(
              height: 50,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFCEB38C),
                  foregroundColor: const Color(0xFF1A1A1A),
                  disabledBackgroundColor: Colors.grey.shade300,
                  disabledForegroundColor: Colors.grey.shade500,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                onPressed: (!_loadingInstructions && _isValid) ? _addToCart : null,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      'Add to Order',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      '•',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '₱${_formatPrice(totalPrice)}',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Lightweight placeholder shown in the Special Instructions area while the
/// instruction groups are being fetched, so the sheet can open instantly.
class _InstructionsLoadingPlaceholder extends StatelessWidget {
  const _InstructionsLoadingPlaceholder();

  @override
  Widget build(BuildContext context) {
    Widget bar(double width) => Container(
          height: 16,
          width: width,
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: Colors.grey.shade200,
            borderRadius: BorderRadius.circular(8),
          ),
        );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              bar(140),
              bar(double.infinity),
              bar(200),
            ],
          ),
        ),
        const SizedBox(width: 12),
        const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Color(0xFFCEB38C),
          ),
        ),
      ],
    );
  }
}

/// Full-screen hold-to-peek overlay with smooth scale and release prompt
class _PeekImageOverlay extends StatelessWidget {
  final String imageUrl;
  final String itemName;

  const _PeekImageOverlay({
    required this.imageUrl,
    required this.itemName,
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Material(
      color: Colors.transparent,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Blurred Dark Backdrop
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                color: Colors.black.withValues(alpha: 0.78),
              ),
            ),
          ),

          // Centered Peek Preview Card
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.88, end: 1.0),
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutBack,
            builder: (context, scale, child) {
              return Transform.scale(
                scale: scale,
                child: child,
              );
            },
            child: Container(
              width: size.width * 0.88,
              constraints: BoxConstraints(
                maxHeight: size.height * 0.7,
                maxWidth: 460,
              ),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.6),
                    blurRadius: 30,
                    spreadRadius: 4,
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                alignment: Alignment.bottomCenter,
                children: [
                  Image.network(
                    imageUrl,
                    fit: BoxFit.contain,
                    errorBuilder: (ctx, error, stackTrace) => const Center(
                      child: Icon(Icons.broken_image, color: Colors.white, size: 64),
                    ),
                  ),

                  // Bottom Title Banner
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.85),
                        ],
                      ),
                    ),
                    child: Text(
                      itemName,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Top "Release to dismiss" pill
          Positioned(
            top: MediaQuery.of(context).padding.top + 24,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Icon(Icons.touch_app_rounded, color: Colors.white, size: 16),
                  SizedBox(width: 6),
                  Text(
                    'Release finger to close',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

