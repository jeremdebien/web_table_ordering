import 'dart:convert';
import 'package:flutter/material.dart';
import '../../data/models/instruction_group_model.dart';

/// Renders the per-item special-instruction questions and reports validity +
/// the answers JSON up to the host dialog via [onChanged].
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
  State<SpecialInstructionsForm> createState() => _SpecialInstructionsFormState();
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
    final hasText = g.allowFreeText && (_freeText[g.id]?.trim().isNotEmpty ?? false);
    return choices + (hasText ? 1 : 0);
  }

  bool get _isValid {
    for (final g in widget.groups) {
      final count = _answerCount(g);
      if (count < g.minSelect) return false;
      if (g.maxSelect != null && count > g.maxSelect!) return false;
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
    if (g.isSingleSelect) return g.isRequired ? 'Select one (required)' : 'Select one';
    final max = g.maxSelect;
    final maxTxt = max == null ? 'any' : '$max';
    if (g.isRequired) return 'Pick ${g.minSelect}–$maxTxt (required)';
    return 'Pick up to $maxTxt';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final g in widget.groups) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  g.label,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
              ),
              Text(
                _hint(g),
                style: TextStyle(
                  fontSize: 11,
                  color: g.isRequired ? const Color(0xfff25125) : Colors.grey,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (g.choices.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: g.choices.map((c) {
                final selected = _selected[g.id]?.contains(c.label) ?? false;
                return ChoiceChip(
                  label: Text(c.label),
                  selected: selected,
                  onSelected: (_) => _toggleChoice(g, c.label),
                  selectedColor: const Color(0xfff25125),
                  labelStyle: TextStyle(color: selected ? Colors.white : Colors.black87),
                );
              }).toList(),
            ),
          if (g.allowFreeText) ...[
            const SizedBox(height: 8),
            TextField(
              decoration: InputDecoration(
                isDense: true,
                hintText: g.choices.isEmpty ? 'Type your answer' : 'Other / notes',
                border: const OutlineInputBorder(),
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
      ],
    );
  }
}
