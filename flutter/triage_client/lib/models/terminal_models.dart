import 'package:flutter/material.dart';

class TerminalColor {
  final int red;
  final int green;
  final int blue;

  const TerminalColor({
    required this.red,
    required this.green,
    required this.blue,
  });

  factory TerminalColor.fromJson(Map<String, dynamic> json) {
    return TerminalColor(
      red: json['red'] as int? ?? 0,
      green: json['green'] as int? ?? 0,
      blue: json['blue'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {'red': red, 'green': green, 'blue': blue};

  Color toColor() => Color.fromARGB(255, red, green, blue);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalColor &&
          red == other.red &&
          green == other.green &&
          blue == other.blue;

  @override
  int get hashCode => red.hashCode ^ green.hashCode ^ blue.hashCode;
}

class TerminalStyle {
  final TerminalColor? foreground;
  final TerminalColor? background;
  final bool bold;
  final bool dim;
  final bool italic;
  final bool underline;
  final bool reverse;

  const TerminalStyle({
    this.foreground,
    this.background,
    this.bold = false,
    this.dim = false,
    this.italic = false,
    this.underline = false,
    this.reverse = false,
  });

  factory TerminalStyle.fromJson(Map<String, dynamic> json) {
    return TerminalStyle(
      foreground: json['foreground'] != null
          ? TerminalColor.fromJson(json['foreground'])
          : null,
      background: json['background'] != null
          ? TerminalColor.fromJson(json['background'])
          : null,
      bold: json['bold'] as bool? ?? false,
      dim: json['dim'] as bool? ?? false,
      italic: json['italic'] as bool? ?? false,
      underline: json['underline'] as bool? ?? false,
      reverse: json['reverse'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'foreground': foreground?.toJson(),
    'background': background?.toJson(),
    'bold': bold,
    'dim': dim,
    'italic': italic,
    'underline': underline,
    'reverse': reverse,
  };
}

class StyledSpan {
  final String text;
  final TerminalStyle style;

  const StyledSpan({required this.text, required this.style});

  factory StyledSpan.fromJson(Map<String, dynamic> json) {
    return StyledSpan(
      text: json['text'] as String? ?? '',
      style: TerminalStyle.fromJson(
        json['style'] as Map<String, dynamic>? ?? {},
      ),
    );
  }

  Map<String, dynamic> toJson() => {'text': text, 'style': style.toJson()};
}

class StyledRow {
  final List<StyledSpan> spans;

  const StyledRow({required this.spans});

  factory StyledRow.fromJson(Map<String, dynamic> json) {
    final spansList = json['spans'] as List<dynamic>? ?? [];
    return StyledRow(
      spans: spansList
          .map((e) => StyledSpan.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'spans': spans.map((e) => e.toJson()).toList(),
  };
}
