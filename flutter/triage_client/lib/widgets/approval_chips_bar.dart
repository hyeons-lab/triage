import 'package:flutter/material.dart';
import 'package:triage_client/terminal/approval_prompt_parser.dart';

/// Compact strip of tap-to-answer approval buttons rendered directly above
/// the mobile keyboard accessory bar whenever the active session is waiting for
/// confirmation.
class ApprovalChipsBar extends StatelessWidget {
  const ApprovalChipsBar({
    super.key,
    required this.prompt,
    required this.onSelect,
  });

  final ApprovalPromptState prompt;
  final void Function(ApprovalChoice choice) onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Color(0xff182022),
        border: Border(top: BorderSide(color: Color(0xff2c383b))),
      ),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(
                Icons.verified_user_outlined,
                size: 14,
                color: Color(0xffffc857),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  prompt.reason,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xffd9e5e3),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final choice in prompt.choices)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onSelect(choice),
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 32),
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: choice.isPrimary
                              ? const Color(0xff2b6a63)
                              : choice.isDestructive
                              ? const Color(0xff4a2529)
                              : const Color(0xff232c2f),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: choice.isPrimary
                                ? const Color(0xff489e94)
                                : choice.isDestructive
                                ? const Color(0xff7d3b42)
                                : const Color(0xff38464a),
                          ),
                        ),
                        child: Text(
                          choice.label,
                          style: const TextStyle(
                            color: Color(0xffedf4f2),
                            fontSize: 12,
                            fontFamily: 'JetBrains Mono',
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
