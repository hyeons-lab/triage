import 'package:url_launcher/url_launcher.dart';

Future<bool> openExternalUri(Uri uri) {
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}
