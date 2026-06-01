String? _stubToken;
String? _stubClientId;

void persistToken(String token) {
  _stubToken = token;
}

String? retrieveToken() {
  return _stubToken;
}

void clearToken() {
  _stubToken = null;
}

void persistClientId(String clientId) {
  _stubClientId = clientId;
}

String? retrieveClientId() {
  return _stubClientId;
}

void clearClientId() {
  _stubClientId = null;
}
