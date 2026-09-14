import 'dart:convert';
import 'package:flutter/material.dart';
import '../../data/models/instruction_group_model.dart';

/// Renders the special-instruction questions (Global, Category, Item level)
/// and reports validity + the answers JSON up to the host dialog via [onChanged].
///
/// Answers JSON shape (only groups with an answer are included):
/// `[{ "group_id": int, "label": str, "choices": [str,...], "free_text": str|null }]`
class SpecialInstructionsForm extends StatefulWidget {
  final List<InstructionGroup> groups;

  /// Called on every change with the current validity and the answers JSON
  /// (null when there are no answers).
  final void Function(bool isValid, String? answersJson) onChanged;

  const SpecialInstructionsForm({
    super.key,
    required this.groups,
    required this.onChanged,
  });

  @override
  State<SpecialInstructionsForm> createState() =>
      _SpecialInstructionsFormState();
}

class _SpecialInstructionsFormState extends State<SpecialInstructionsForm> {
  // group id -> selected choice labels
  final Map<int, Set<String>> _selected = {};
  // group id -> free text
  final Map<int, String> _freeText = {};

  @override
  void initState() {
    super.initState();
    // Emit initial validity so the host can set the button state before any input.
    WidgetsBinding.instance.addPostFrameCallback((_) => _emit());
  }

  int _answerCount(InstructionGroup g) {
    final choices = _selected[g.id]?.length ?? 0;
    final hasText =
        g.allowFreeText && (_freeText[g.id]?.trim().isNotEmpty ?? false);
    return choices + (hasText ? 1 : 0);
  }

  bool _isGroupSatisfied(InstructionGroup g) {
    final count = _answerCount(g);
    if (g.isRequired && count < g.minSelect) return false;
    if (g.maxSelect != null && count > g.maxSelect!) return false;
    return true;
  }

  bool get _isValid {
    for (final g in widget.groups) {
      if (!_isGroupSatisfied(g)) return false;
    }
    return true;
  }

  String? _buildJson() {
    final result = <Map<String, dynamic>>[];
    for (final g in widget.groups) {
      final choices = (_selected[g.id]?.toList() ?? <String>[])..sort();
      final text = _freeText[g.id]?.trim() ?? '';
      if (choices.isEmpty && text.isEmpty) continue;
      result.add({
        'group_id': g.id,
        'label': g.label,
        'choices': choices,
        'free_text': text.isEmpty ? null : text,
      });
    }
    return result.isEmpty ? null : jsonEncode(result);
  }

  void _emit() => widget.onChanged(_isValid, _buildJson());

  void _toggleChoice(InstructionGroup g, String label) {
    setState(() {
      final set = _selected.putIfAbsent(g.id, () => <String>{});
      if (g.isSingleSelect) {
        // Radio behavior: replace (or clear if tapping the selected one and
        // the group is optional).
        if (set.contains(label)) {
          if (!g.isRequired) set.clear();
        } else {
          set
            ..clear()
            ..add(label);
        }
      } else {
        if (set.contains(label)) {
          set.remove(label);
        } else {
          final max = g.maxSelect;
          if (max == null || set.length < max) set.add(label);
        }
      }
    });
    _emit();
  }

  String _hint(InstructionGroup g) {
    if (g.isSingleSelect) {
      return g.isRequired ? 'Select 1 option (Required)' : 'Select 1 option (Optional)';
    }
    final max = g.maxSelect;
    final maxTxt = max == null ? 'unlimited' : 'max $max';
    if (g.isRequired) return 'Pick ${g.minSelect}–$maxTxt (Required)';
    return 'Pick up to $maxTxt (Optional)';
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFFC5A880);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final g in widget.groups) ...[
          Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: g.isRequired && !_isGroupSatisfied(g)
                    ? const Color(0xFFE25822).withValues(alpha: 0.5)
                    : const Color(0xFFE5E7EB),
                width: g.isRequired && !_isGroupSatisfied(g) ? 1.5 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header row
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        g.label,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1A1A1A),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: g.isRequired
                            ? const Color(0xFFE25822).withValues(alpha: 0.1)
                            : Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        g.isRequired ? 'REQUIRED' : 'OPTIONAL',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: g.isRequired
                              ? const Color(0xFFE25822)
                              : Colors.grey.shade700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _hint(g),
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade600,
                  ),
                ),
                const SizedBox(height: 12),
                // Choices
                if (g.choices.isNotEmpty)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: g.choices.map((c) {
                      final isSelected =
                          _selected[g.id]?.contains(c.label) ?? false;
                      return InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => _toggleChoice(g, c.label),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? const Color(0xFF1A1A1A)
                                : Colors.white,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isSelected
                                  ? const Color(0xFF1A1A1A)
                                  : const Color(0xFFD1D5DB),
                              width: isSelected ? 1.5 : 1,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                g.isSingleSelect
                                    ? (isSelected
                                        ? Icons.radio_button_checked
                                        : Icons.radio_button_off)
                                    : (isSelected
                                        ? Icons.check_box
                                        : Icons.check_box_outline_blank),
                                size: 16,
                                color: isSelected ? accent : Colors.black45,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                c.label,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: isSelected
                                      ? FontWeight.bold
                                      : FontWeight.w500,
                                  color: isSelected
                                      ? Colors.white
                                      : const Color(0xFF1A1A1A),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                // Free text note
                if (g.allowFreeText) ...[
                  const SizedBox(height: 10),
                  TextField(
                    decoration: InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: Colors.white,
                      hintText: g.choices.isEmpty
                          ? 'Type your special instructions / note here...'
                          : 'Other notes / custom request...',
                      hintStyle: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade400,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(
                          color: Color(0xFF1A1A1A),
                          width: 1.5,
                        ),
                      ),
                    ),
                    minLines: 1,
                    maxLines: 3,
                    onChanged: (v) {
                      _freeText[g.id] = v;
                      _emit();
                    },
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}
