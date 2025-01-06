import 'dart:convert';
import 'dart:io';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:http/http.dart' as http;

import 'auth_test.mocks.dart';

@GenerateMocks([http.Client])
void main() {
  group('Auth class functionality', () {
    late MockClient mockClient;
    late Auth auth;

    setUp(() {
      mockClient = MockClient();
      auth = Auth(
        accessToken: 'initialAccessToken',
        refreshToken: 'initialRefreshToken',
        refreshUrl: 'https://example.com/refresh',
        accessTokenExpiryTime: DateTime.now()
            .subtract(const Duration(seconds: 10)), // expired token
      );
    });

    test('No change if token not expired', () async {
      // Set up mock response for refresh request
      when(mockClient.post(
        Uri.parse(auth.refreshUrl!),
        headers: auth.refreshHeaders,
        body: jsonEncode({'refresh_token': auth.refreshToken}),
      )).thenAnswer((_) async => http.Response(
          jsonEncode({'access_token': 'newAccessToken', 'expires_in': 3600}),
          200));
      auth.accessTokenExpiryTime = null; // never expires
      auth.accessQueryParams = {'accessToken': '{accessToken}'};
      Uri uri = await auth.getAccessUri(
        url: 'https://example.com/resource',
        httpClient: mockClient,
      );
      // Verify that the URI includes original query parameters
      expect(uri.queryParameters['accessToken'], 'initialAccessToken');
      expect(auth.accessToken, 'initialAccessToken');
    });

    test('HttpException if client returns error', () async {
      // Set up mock response for refresh request
      when(mockClient.post(
        Uri.parse(auth.refreshUrl!),
        headers: auth.refreshHeaders,
        body: jsonEncode({'refresh_token': auth.refreshToken}),
      )).thenAnswer((_) async => http.Response('', 400));
      auth.accessQueryParams = {'accessToken': '{accessToken}'};
      expect(
          () => auth.getAccessUri(
                url: 'https://example.com/resource',
                httpClient: mockClient,
              ),
          throwsA(const HttpException('Could not refresh access token')));
    });

    test('Token refresh updates accessToken and accessTokenExpiryTime',
        () async {
      // Set up mock response for refresh request
      when(mockClient.post(
        Uri.parse(auth.refreshUrl!),
        headers: {'Content-type': 'application/json'},
        body: jsonEncode({
          'grant_type': 'refresh_token',
          'refresh_token': auth.refreshToken
        }),
      )).thenAnswer((_) async => http.Response(
          jsonEncode({
            'access_token': 'newAccessToken',
            'expires_in': 3600,
            'refresh_token': 'newRefreshToken'
          }),
          200));
      final (updatedAccessToken, updatedRefreshToken) =
          await auth.refreshAccessToken(
        httpClient: mockClient,
      );
      // Check if tokens and expiry time are updated
      expect(updatedAccessToken, true);
      expect(updatedRefreshToken, true);
      expect(auth.accessToken, 'newAccessToken');
      expect(auth.refreshToken, 'newRefreshToken');
      expect(auth.accessTokenExpiryTime!.isAfter(DateTime.now()), true);
    });

    test('getAccessUri refreshes token if expired', () async {
      // Set up mock response for refresh request
      when(mockClient.post(
        Uri.parse(auth.refreshUrl!),
        headers: {'Content-type': 'application/json'},
        body: jsonEncode({
          'grant_type': 'refresh_token',
          'refresh_token': auth.refreshToken
        }),
      )).thenAnswer((_) async => http.Response(
          jsonEncode({'access_token': 'newAccessToken', 'expires_in': 3600}),
          200));
      auth.accessQueryParams = {'accessToken': '{accessToken}'};
      Uri uri = await auth.getAccessUri(
        url: 'https://example.com/resource',
        httpClient: mockClient,
      );
      // Verify that the URI includes updated query parameters
      expect(uri.queryParameters['accessToken'], 'newAccessToken');
      expect(auth.accessToken, 'newAccessToken');
    });

    test('getAccessHeaders returns headers with updated accessToken', () {
      auth.accessToken = 'updatedAccessToken';
      auth.accessHeaders = {'Authorization': 'Bearer {accessToken}'};
      final headers = auth.getAccessHeaders();
      // Check that the accessToken is replaced in the headers
      expect(headers['Authorization'], 'Bearer updatedAccessToken');
    });

    test('isTokenExpired returns true for expired token', () {
      auth.accessTokenExpiryTime =
          DateTime.now().subtract(const Duration(seconds: 1));
      expect(auth.isTokenExpired(), true);
    });

    test('isTokenExpired returns false for non-expired token', () {
      auth.accessTokenExpiryTime =
          DateTime.now().add(const Duration(seconds: 3600));
      expect(auth.isTokenExpired(), false);
    });

    test('getAccessQueryParams includes access token in query parameters', () {
      auth.accessToken = 'testAccessToken';
      auth.accessQueryParams = {'token': '{accessToken}'};
      final queryParams = auth.getAccessQueryParams();
      // Check if the accessToken is correctly included
      expect(queryParams['token'], 'testAccessToken');
    });
  });

  group('Auth JSON serialization tests', () {
    test('toJson returns correct JSON map', () {
      final auth = Auth(
        accessToken: 'testAccessToken',
        accessHeaders: {'Authorization': 'Bearer {accessToken}'},
        accessQueryParams: {'token': '{accessToken}'},
        accessTokenExpiryTime:
            DateTime.fromMillisecondsSinceEpoch(1672531199000),
        refreshToken: 'testRefreshToken',
        refreshUrl: 'https://example.com/refresh',
        refreshHeaders: {'Content-Type': 'application/json'},
        refreshQueryParams: {'grant_type': 'refresh_token'},
      );
      final json = auth.toJson();
      // Check JSON structure
      expect(json['accessToken'], 'testAccessToken');
      expect(json['accessHeaders'], {'Authorization': 'Bearer {accessToken}'});
      expect(json['accessQueryParams'], {'token': '{accessToken}'});
      expect(json['accessTokenExpiryTime'],
          1672531199000); // Milliseconds since epoch
      expect(json['refreshToken'], 'testRefreshToken');
      expect(json['refreshUrl'], 'https://example.com/refresh');
      expect(json['refreshHeaders'], {'Content-Type': 'application/json'});
      expect(json['refreshQueryParams'], {'grant_type': 'refresh_token'});
    });

    test('fromJson creates an Auth object from JSON map', () {
      final json = {
        'accessToken': 'testAccessToken',
        'accessHeaders': {'Authorization': 'Bearer {accessToken}'},
        'accessQueryParams': {'token': '{accessToken}'},
        'accessTokenExpiryTime': 1672531199000,
        'refreshToken': 'testRefreshToken',
        'refreshUrl': 'https://example.com/refresh',
        'refreshHeaders': {'Content-Type': 'application/json'},
        'refreshQueryParams': {'grant_type': 'refresh_token'},
      };
      final auth = Auth.fromJson(json);
      // Check if fields are correctly populated
      expect(auth.accessToken, 'testAccessToken');
      expect(auth.accessHeaders, {'Authorization': 'Bearer {accessToken}'});
      expect(auth.accessQueryParams, {'token': '{accessToken}'});
      expect(auth.accessTokenExpiryTime,
          DateTime.fromMillisecondsSinceEpoch(1672531199000));
      expect(auth.refreshToken, 'testRefreshToken');
      expect(auth.refreshUrl, 'https://example.com/refresh');
      expect(auth.refreshHeaders, {'Content-Type': 'application/json'});
      expect(auth.refreshQueryParams, {'grant_type': 'refresh_token'});
    });

    test('toJson and fromJson consistency', () {
      final originalAuth = Auth(
        accessToken: 'consistentAccessToken',
        accessHeaders: {'Authorization': 'Bearer {accessToken}'},
        accessQueryParams: {'token': '{accessToken}'},
        accessTokenExpiryTime:
            DateTime.fromMillisecondsSinceEpoch(1672531199000),
        refreshToken: 'consistentRefreshToken',
        refreshUrl: 'https://example.com/consistent_refresh',
        refreshHeaders: {'Content-Type': 'application/json'},
        refreshQueryParams: {'grant_type': 'refresh_token'},
      );
      // Convert to JSON and back to an Auth instance
      final json = originalAuth.toJson();
      final newAuth = Auth.fromJson({
        'accessToken': json['accessToken'],
        'accessHeaders': json['accessHeaders'],
        'accessQueryParams': json['accessQueryParams'],
        'accessTokenExpiryTime': json['accessTokenExpiryTime'],
        'refreshToken': json['refreshToken'],
        'refreshUrl': json['refreshUrl'],
        'refreshHeaders': json['refreshHeaders'],
        'refreshQueryParams': json['refreshQueryParams'],
      });
      // Check if new Auth object matches the original one
      expect(newAuth.accessToken, originalAuth.accessToken);
      expect(newAuth.accessHeaders, originalAuth.accessHeaders);
      expect(newAuth.accessQueryParams, originalAuth.accessQueryParams);
      expect(newAuth.accessTokenExpiryTime, originalAuth.accessTokenExpiryTime);
      expect(newAuth.refreshToken, originalAuth.refreshToken);
      expect(newAuth.refreshUrl, originalAuth.refreshUrl);
      expect(newAuth.refreshHeaders, originalAuth.refreshHeaders);
      expect(newAuth.refreshQueryParams, originalAuth.refreshQueryParams);
    });

    test('Handles null values in nullable properties', () {
      final auth = Auth(
        accessToken: null,
        accessHeaders: {},
        accessQueryParams: {},
        accessTokenExpiryTime: null,
        refreshToken: null,
        refreshUrl: null,
        refreshHeaders: {},
        refreshQueryParams: {},
      );
      final json = auth.toJson();
      // Ensure nullable properties are null in JSON output
      expect(json['accessToken'], null);
      expect(json['accessTokenExpiryTime'], null);
      expect(json['refreshToken'], null);
      expect(json['refreshUrl'], null);
      // Convert back from JSON to Auth and check that fields are still null
      final newAuth = Auth.fromJson({
        'accessToken': json['accessToken'],
        'authHeaders': json['accessHeaders'],
        'accessQueryParams': json['accessQueryParams'],
        'accessTokenExpiryTime': json['accessTokenExpiryTime'],
        'reAuthToken': json['refreshToken'],
        'tokenRefreshUrl': json['refreshUrl'],
        'refreshHeaders': json['refreshHeaders'],
        'refreshQueryParams': json['refreshQueryParams'],
      });
      expect(newAuth.accessToken, null);
      expect(newAuth.accessTokenExpiryTime, null);
      expect(newAuth.refreshToken, null);
      expect(newAuth.refreshUrl, null);
    });
  });
}
