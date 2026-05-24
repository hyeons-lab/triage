String? _stubToken;
String? _stubClientId;

void persistToken(String token) {
  _stubToken = token;
}

String? retrieveToken() {
  return _stubToken;
}

void persistClientId(String clientId) {
  _stubClientId = clientId;
}

String? retrieveClientId() {
  return _stubClientId;
}
