String defaultWebSocketUrl() {
  final Uri base = Uri.base;
  final String host = base.host.isEmpty ? '127.0.0.1' : base.host;
  return 'ws://$host:8081';
}
