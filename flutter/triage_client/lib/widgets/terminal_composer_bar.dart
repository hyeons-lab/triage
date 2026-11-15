import 'package:flutter/material.dart';

/// Toggleable multiline draft composer sitting above [TerminalAccessoryBar] on
/// mobile so users can compose and swipe multi-word prompts before sending.
class TerminalComposerBar extends StatelessWidget {
  const TerminalComposerBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.onSend,
    required this.onClose,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final VoidCallback onSend;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Color(0xff141a1c),
        border: Border(top: BorderSide(color: Color(0xff2b363a))),
      ),
      padding: const EdgeInsets.fromLTRB(10, 6, 8, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) {
                return TextField(
                  controller: controller,
                  focusNode: focusNode,
                  enabled: enabled,
                  minLines: 1,
                  maxLines: 4,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  autocorrect: true,
                  enableSuggestions: true,
                  style: const TextStyle(
                    color: Color(0xffedf4f2),
                    fontSize: 14,
                    fontFamily: 'JetBrains Mono',
                  ),
                  decoration: InputDecoration(
                    hintText: 'Compose message or command...',
                    hintStyle: const TextStyle(
                      color: Color(0xff7f8b8d),
                      fontSize: 13,
                    ),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    filled: true,
                    fillColor: const Color(0xff0d1113),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xff2d383c)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xff2d383c)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xff489e94)),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 6),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              final canSend = enabled && value.text.trim().isNotEmpty;
              return IconButton(
                tooltip: 'Send draft',
                onPressed: canSend ? onSend : null,
                icon: const Icon(Icons.send_rounded, size: 19),
                color: const Color(0xff7fd1c7),
                disabledColor: const Color(0xff465256),
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                padding: EdgeInsets.zero,
              );
            },
          ),
          IconButton(
            tooltip: 'Close composer',
            onPressed: onClose,
            icon: const Icon(Icons.keyboard_hide_outlined, size: 18),
            color: const Color(0xff8e9c9e),
            constraints: const BoxConstraints(minWidth: 34, minHeight: 36),
            padding: EdgeInsets.zero,
          ),
        ],
      ),
    );
  }
}
