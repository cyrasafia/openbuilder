import 'package:flutter/widgets.dart';

import '../domain/models.dart';
import '../l10n/gen/app_localizations.dart';

/// Convenience accessor for the active [AppLocalizations].
AppLocalizations l(BuildContext context) => AppLocalizations.of(context)!;

/// Localized permission title derived from [Permission.type], shared by the
/// conversation permission card (has context) and the notification body (no
/// context — loads loc via delegate) so the type→title mapping never drifts.
String permissionTitle(AppLocalizations loc, Permission p) {
  switch (p.type) {
    case 'external_directory':
      final dir = p.externalDirectoryPath;
      return dir != null
          ? loc.permissionAccessDir(dir)
          : loc.permissionExternalAccess;
    case 'bash':
      return loc.permissionExecute;
    default:
      return p.type.isEmpty ? loc.permissionRequest : p.type;
  }
}
