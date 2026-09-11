import 'package:flutter/material.dart';

/// A custom, draggable scrollbar overlay for the terminal pane.
///
/// Unlike standard Flutter scrollbars which can lose pointer events or gesture
/// arena ownership to terminal text selection handlers, this scrollbar sits in
/// the pane stack with opaque hit-testing over its track. Pointer down and drag
/// events on the scrollbar directly drive the scroll controller without triggering
/// text selection in the underlying terminal view.
class TerminalScrollbar extends StatefulWidget {
  const TerminalScrollbar({
    super.key,
    required this.controller,
    required this.child,
    this.enabled = true,
    this.width = 14.0,
    this.minThumbHeight = 28.0,
  });

  final ScrollController controller;
  final Widget child;
  final bool enabled;
  final double width;
  final double minThumbHeight;

  @override
  State<TerminalScrollbar> createState() => _TerminalScrollbarState();
}

class _TerminalScrollbarState extends State<TerminalScrollbar> {
  bool _isHovered = false;
  bool _isDragging = false;
  bool _metricsUpdateScheduled = false;
  double? _dragStartLocalY;
  double? _dragStartPixels;

  @override
  void didUpdateWidget(TerminalScrollbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _isDragging = false;
      _dragStartLocalY = null;
      _dragStartPixels = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return widget.child;
    }

    return NotificationListener<Notification>(
      onNotification: (notification) {
        if (notification is ScrollMetricsNotification &&
            notification.depth == 0) {
          if (!_metricsUpdateScheduled) {
            _metricsUpdateScheduled = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _metricsUpdateScheduled = false;
              if (mounted) {
                setState(() {});
              }
            });
          }
        }
        return false;
      },
      child: Stack(
        fit: StackFit.expand,
        children: [widget.child, _buildScrollbarOverlay()],
      ),
    );
  }

  Widget _buildScrollbarOverlay() {
    return Positioned(
      top: 0,
      bottom: 0,
      right: 0,
      width: widget.width,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final trackHeight = constraints.maxHeight;
          if (trackHeight <= 0) return const SizedBox.shrink();

          return AnimatedBuilder(
            animation: widget.controller,
            builder: (context, _) {
              if (!widget.controller.hasClients ||
                  widget.controller.positions.length != 1) {
                return const SizedBox.shrink();
              }
              final position = widget.controller.position;
              if (!position.hasContentDimensions ||
                  position.maxScrollExtent <= 0) {
                return const SizedBox.shrink();
              }

              final maxScroll = position.maxScrollExtent;
              final viewport = position.viewportDimension;
              final pixels = position.pixels.isFinite
                  ? position.pixels.clamp(0.0, maxScroll)
                  : 0.0;

              final effectiveMinThumbHeight = widget.minThumbHeight.clamp(
                0.0,
                trackHeight,
              );
              final thumbHeight =
                  (viewport / (viewport + maxScroll) * trackHeight).clamp(
                    effectiveMinThumbHeight,
                    trackHeight,
                  );
              final availableTrack = trackHeight - thumbHeight;
              final thumbTop = availableTrack > 0
                  ? (pixels / maxScroll) * availableTrack
                  : 0.0;

              final active = _isDragging || _isHovered;
              final thumbColor = active
                  ? const Color(0xff7fd1c7)
                  : const Color(0x4cd9e5e3);

              return MouseRegion(
                cursor: SystemMouseCursors.basic,
                onEnter: (_) => setState(() => _isHovered = true),
                onExit: (_) => setState(() => _isHovered = false),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) {
                    final clickY = details.localPosition.dy;
                    if (availableTrack <= 0 ||
                        !widget.controller.hasClients ||
                        !widget.controller.position.hasContentDimensions) {
                      return;
                    }
                    if (clickY < thumbTop || clickY > thumbTop + thumbHeight) {
                      final targetPixels =
                          ((clickY - thumbHeight / 2) /
                                  availableTrack *
                                  maxScroll)
                              .clamp(0.0, maxScroll);
                      widget.controller.jumpTo(targetPixels);
                    }
                  },
                  onVerticalDragStart: (details) {
                    setState(() => _isDragging = true);
                    _dragStartLocalY = details.localPosition.dy;
                    _dragStartPixels = position.pixels;
                  },
                  onVerticalDragUpdate: (details) {
                    final startY = _dragStartLocalY;
                    final startPixels = _dragStartPixels;
                    if (startY == null ||
                        startPixels == null ||
                        availableTrack <= 0 ||
                        !widget.controller.hasClients ||
                        !widget.controller.position.hasContentDimensions) {
                      return;
                    }

                    final deltaY = details.localPosition.dy - startY;
                    final deltaPixels = (deltaY / availableTrack) * maxScroll;
                    final targetPixels = (startPixels + deltaPixels).clamp(
                      0.0,
                      maxScroll,
                    );
                    widget.controller.jumpTo(targetPixels);
                  },
                  onVerticalDragEnd: (_) {
                    setState(() {
                      _isDragging = false;
                      _dragStartLocalY = null;
                      _dragStartPixels = null;
                    });
                  },
                  onVerticalDragCancel: () {
                    setState(() {
                      _isDragging = false;
                      _dragStartLocalY = null;
                      _dragStartPixels = null;
                    });
                  },
                  child: Stack(
                    children: [
                      Positioned(
                        top: thumbTop,
                        right: 3,
                        width: 8,
                        height: thumbHeight,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: thumbColor,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
