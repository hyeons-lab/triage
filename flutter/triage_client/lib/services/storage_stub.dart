String? _stubToken;

void persistToken(String token) {
  _stubToken = token;
}

String? retrieveToken() {
  return _stubToken;
}
