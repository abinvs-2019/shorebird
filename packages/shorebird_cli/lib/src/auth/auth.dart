import 'dart:convert';
import 'dart:io';

import 'package:cli_util/cli_util.dart';
import 'package:googleapis_auth/auth_io.dart' as oauth2;
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:scoped/scoped.dart';
import 'package:shorebird_cli/src/auth/jwt.dart';
import 'package:shorebird_cli/src/command.dart';
import 'package:shorebird_cli/src/command_runner.dart';
import 'package:shorebird_cli/src/http_client/http_client.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';

// A reference to a [Auth] instance.
final authRef = create(Auth.new);

// The [Auth] instance available in the current zone.
Auth get auth => read(authRef);

final _clientId = oauth2.ClientId(
  /// Shorebird CLI's OAuth 2.0 identifier.
  '523302233293-eia5antm0tgvek240t46orctktiabrek.apps.googleusercontent.com',

  /// Shorebird CLI's OAuth 2.0 secret.
  ///
  /// This isn't actually meant to be kept secret.
  /// There is no way to properly secure a secret for installed/console applications.
  /// Fortunately the OAuth2 flow used in this case assumes that the app cannot
  /// keep secrets so this particular secret DOES NOT need to be kept secret.
  /// You should however make sure not to re-use the same secret
  /// anywhere secrecy is required.
  ///
  /// For more info see: https://developers.google.com/identity/protocols/oauth2/native-app
  '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',
);
final _scopes = ['openid', 'https://www.googleapis.com/auth/userinfo.email'];

typedef ObtainAccessCredentials = Future<oauth2.AccessCredentials> Function(
  oauth2.ClientId clientId,
  List<String> scopes,
  http.Client client,
  void Function(String) userPrompt,
);

typedef RefreshCredentials = Future<oauth2.AccessCredentials> Function(
  oauth2.ClientId clientId,
  oauth2.AccessCredentials credentials,
  http.Client client,
);

typedef OnRefreshCredentials = void Function(
  oauth2.AccessCredentials credentials,
);

class AuthenticatedClient extends http.BaseClient {
  AuthenticatedClient.credentials({
    required http.Client httpClient,
    required oauth2.AccessCredentials credentials,
    OnRefreshCredentials? onRefreshCredentials,
    RefreshCredentials refreshCredentials = oauth2.refreshCredentials,
  }) : this._(
          httpClient: httpClient,
          onRefreshCredentials: onRefreshCredentials,
          credentials: credentials,
          refreshCredentials: refreshCredentials,
        );

  AuthenticatedClient.token({
    required http.Client httpClient,
    required String token,
    OnRefreshCredentials? onRefreshCredentials,
    RefreshCredentials refreshCredentials = oauth2.refreshCredentials,
  }) : this._(
          httpClient: httpClient,
          token: token,
          onRefreshCredentials: onRefreshCredentials,
          refreshCredentials: refreshCredentials,
        );

  AuthenticatedClient._({
    required http.Client httpClient,
    OnRefreshCredentials? onRefreshCredentials,
    oauth2.AccessCredentials? credentials,
    String? token,
    RefreshCredentials refreshCredentials = oauth2.refreshCredentials,
  })  : _baseClient = httpClient,
        _credentials = credentials,
        _onRefreshCredentials = onRefreshCredentials,
        _refreshCredentials = refreshCredentials,
        _token = token;

  final http.Client _baseClient;
  final OnRefreshCredentials? _onRefreshCredentials;
  final RefreshCredentials _refreshCredentials;
  oauth2.AccessCredentials? _credentials;
  final String? _token;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    var credentials = _credentials;

    if (credentials == null) {
      final token = _token!;
      credentials = _credentials = await _refreshCredentials(
        _clientId,
        oauth2.AccessCredentials(
          // This isn't relevant for a refresh operation.
          AccessToken('Bearer', '', DateTime.timestamp()),
          token,
          _scopes,
        ),
        _baseClient,
      );
      _onRefreshCredentials?.call(credentials);
    }

    if (credentials.accessToken.hasExpired) {
      credentials = _credentials = await _refreshCredentials(
        _clientId,
        credentials,
        _baseClient,
      );
      _onRefreshCredentials?.call(credentials);
    }

    final token = credentials.idToken;
    request.headers['Authorization'] = 'Bearer $token';
    return _baseClient.send(request);
  }
}

class Auth {
  Auth({
    http.Client? httpClient,
    String? credentialsDir,
    ObtainAccessCredentials? obtainAccessCredentials,
    CodePushClientBuilder? buildCodePushClient,
  })  : _httpClient = httpClient ?? _defaultHttpClient,
        _credentialsDir =
            credentialsDir ?? applicationConfigHome(executableName),
        _obtainAccessCredentials = obtainAccessCredentials ??
            oauth2.obtainAccessCredentialsViaUserConsent,
        _buildCodePushClient = buildCodePushClient ?? CodePushClient.new {
    _loadCredentials();
  }

  static http.Client get _defaultHttpClient => retryingHttpClient(
        LoggingClient(httpClient: http.Client()),
      );

  final http.Client _httpClient;
  final String _credentialsDir;
  final ObtainAccessCredentials _obtainAccessCredentials;
  final CodePushClientBuilder _buildCodePushClient;
  String? _token;

  String get credentialsFilePath {
    return p.join(_credentialsDir, 'credentials.json');
  }

  http.Client get client {
    if (_credentials == null && _token == null) {
      return _httpClient;
    }

    if (_token != null) {
      return AuthenticatedClient.token(token: _token!, httpClient: _httpClient);
    }

    return AuthenticatedClient.credentials(
      credentials: _credentials!,
      httpClient: _httpClient,
      onRefreshCredentials: _flushCredentials,
    );
  }

  Future<AccessCredentials> loginCI(void Function(String) prompt) async {
    final client = http.Client();
    try {
      final credentials = await _obtainAccessCredentials(
        _clientId,
        _scopes,
        client,
        prompt,
      );

      final codePushClient = _buildCodePushClient(
        httpClient: AuthenticatedClient.credentials(
          credentials: credentials,
          httpClient: _httpClient,
        ),
      );
      final user = await codePushClient.getCurrentUser();
      if (user == null) {
        throw UserNotFoundException(email: credentials.email!);
      }
      return credentials;
    } finally {
      client.close();
    }
  }

  Future<void> login(void Function(String) prompt) async {
    if (_credentials != null) {
      throw UserAlreadyLoggedInException(email: _credentials!.email!);
    }

    final client = http.Client();
    try {
      _credentials = await _obtainAccessCredentials(
        _clientId,
        _scopes,
        client,
        prompt,
      );

      final codePushClient = _buildCodePushClient(httpClient: this.client);

      final user = await codePushClient.getCurrentUser();
      if (user == null) {
        throw UserNotFoundException(email: _credentials!.email!);
      }

      _email = user.email;
      _flushCredentials(_credentials!);
    } finally {
      client.close();
    }
  }

  void logout() => _clearCredentials();

  oauth2.AccessCredentials? _credentials;

  String? _email;

  String? get email => _email;

  bool get isAuthenticated => _email != null || _token != null;

  void _loadCredentials() {
    final token = platform.environment['SHOREBIRD_TOKEN'];
    if (token != null) {
      _token = token;
      return;
    }

    final credentialsFile = File(credentialsFilePath);
    if (credentialsFile.existsSync()) {
      try {
        final contents = credentialsFile.readAsStringSync();
        _credentials = oauth2.AccessCredentials.fromJson(
          json.decode(contents) as Map<String, dynamic>,
        );
        _email = _credentials?.email;
      } catch (_) {}
    }
  }

  void _flushCredentials(oauth2.AccessCredentials credentials) {
    File(credentialsFilePath)
      ..createSync(recursive: true)
      ..writeAsStringSync(json.encode(credentials.toJson()));
  }

  void _clearCredentials() {
    _credentials = null;
    _email = null;

    final credentialsFile = File(credentialsFilePath);
    if (credentialsFile.existsSync()) {
      credentialsFile.deleteSync(recursive: true);
    }
  }

  void close() {
    _httpClient.close();
  }
}

extension on oauth2.AccessCredentials {
  String? get email {
    final token = idToken;

    if (token == null) return null;

    final claims = Jwt.decodeClaims(token);

    if (claims == null) return null;

    return claims['email'] as String?;
  }
}

/// Thrown when an already authenticated user attempts to log in or sign up.
class UserAlreadyLoggedInException implements Exception {
  /// {@macro user_already_logged_in_exception}
  UserAlreadyLoggedInException({required this.email});

  /// The email of the already authenticated user, as derived from the stored
  /// auth credentials.
  final String email;
}

/// {@template user_not_found_exception}
/// Thrown when an attempt to fetch a User object results in a 404.
/// {@endtemplate}
class UserNotFoundException implements Exception {
  /// {@macro user_not_found_exception}
  UserNotFoundException({required this.email});

  /// The email used to locate the user, as derived from the stored auth
  /// credentials.
  final String email;
}
