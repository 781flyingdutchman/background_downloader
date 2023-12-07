import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

const workingUrl = 'https://google.com';
const failingUrl = 'https://avmaps-dot-bbflightserver-hrd.appspot'
    '.com/public/get_current_app_data?key=background_downloader_integration_test';
const urlWithContentLength = 'https://storage.googleapis'
    '.com/approachcharts/test/5MB-test.ZIP';
const urlWithLongContentLength = 'https://storage.googleapis'
    '.com/approachcharts/test/57MB-test.ZIP';
const getTestUrl =
    'https://avmaps-dot-bbflightserver-hrd.appspot.com/public/test_get_data';
const getRedirectTestUrl =
    'https://avmaps-dot-bbflightserver-hrd.appspot.com/public/test_get_redirect';
const postTestUrl =
    'https://avmaps-dot-bbflightserver-hrd.appspot.com/public/test_post_data';
const uploadTestUrl =
    'https://avmaps-dot-bbflightserver-hrd.appspot.com/public/test_upload_file';
const uploadBinaryTestUrl =
    'https://avmaps-dot-bbflightserver-hrd.appspot.com/public/test_upload_binary_file';
const uploadMultiTestUrl =
    'https://avmaps-dot-bbflightserver-hrd.appspot.com/public/test_multi_upload_file';
const urlWithContentLengthFileSize = 6207471;

const defaultFilename = 'google.html';
const postFilename = 'post.txt';
const uploadFilename = 'a_file.txt';
const uploadFilename2 = 'second_file.txt';
const largeFilename = '5MB-test.ZIP';

var task = DownloadTask(url: workingUrl, filename: defaultFilename);

var retryTask =
    DownloadTask(url: failingUrl, filename: defaultFilename, retries: 3);

var uploadTask = UploadTask(url: uploadTestUrl, filename: uploadFilename);
var uploadTaskBinary = uploadTask.copyWith(post: 'binary');

void main() {
  test('TaskProgressUpdate', () {
    final task = DownloadTask(url: 'http://google.com');
    var update = TaskProgressUpdate(task, 0.1);
    expect(update.hasExpectedFileSize, isFalse);
    expect(update.hasNetworkSpeed, isFalse);
    expect(update.hasTimeRemaining, isFalse);
    expect(update.networkSpeedAsString, equals('-- MB/s'));
    expect(update.timeRemainingAsString, equals('--:--'));
    update =
        TaskProgressUpdate(task, 0.1, 123, 0.2, const Duration(seconds: 30));
    expect(update.hasExpectedFileSize, isTrue);
    expect(update.hasNetworkSpeed, isTrue);
    expect(update.hasTimeRemaining, isTrue);
    expect(update.networkSpeedAsString, equals('200 kB/s'));
    expect(update.timeRemainingAsString, equals('00:30'));
    update = TaskProgressUpdate(task, 0.1, 123, 2, const Duration(seconds: 90));
    expect(update.networkSpeedAsString, equals('2 MB/s'));
    expect(update.timeRemainingAsString, equals('01:30'));
    update =
        TaskProgressUpdate(task, 0.1, 123, 1.1, const Duration(seconds: 3610));
    expect(update.networkSpeedAsString, equals('1 MB/s'));
    expect(update.timeRemainingAsString, equals('1:00:10'));
  });

  test('copyWith', () async {
    final complexTask = DownloadTask(
        taskId: 'uniqueId',
        url: postTestUrl,
        filename: defaultFilename,
        headers: {'Auth': 'Test'},
        httpRequestMethod: 'PATCH',
        post: 'TestPost',
        directory: 'directory',
        baseDirectory: BaseDirectory.temporary,
        group: 'someGroup',
        updates: Updates.statusAndProgress,
        requiresWiFi: true,
        retries: 5,
        metaData: 'someMetaData');
    final now = DateTime.now();
    expect(
        now.difference(complexTask.creationTime).inMilliseconds, lessThan(100));
    final task = complexTask.copyWith(); // all the same
    expect(task.taskId, equals(complexTask.taskId));
    expect(task.url, equals(complexTask.url));
    expect(task.filename, equals(complexTask.filename));
    expect(task.headers, equals(complexTask.headers));
    expect(task.httpRequestMethod, equals(complexTask.httpRequestMethod));
    expect(task.post, equals(complexTask.post));
    expect(task.directory, equals(complexTask.directory));
    expect(task.baseDirectory, equals(complexTask.baseDirectory));
    expect(task.group, equals(complexTask.group));
    expect(task.updates, equals(complexTask.updates));
    expect(task.requiresWiFi, equals(complexTask.requiresWiFi));
    expect(task.retries, equals(complexTask.retries));
    expect(task.retriesRemaining, equals(complexTask.retriesRemaining));
    expect(task.retriesRemaining, equals(task.retries));
    expect(task.metaData, equals(complexTask.metaData));
    expect(task.creationTime, equals(complexTask.creationTime));
  });

  test('downloadTask url and urlQueryParameters', () {
    final task0 = DownloadTask(
        url: 'url with space',
        filename: defaultFilename,
        urlQueryParameters: {});
    expect(task0.url, equals('url with space'));
    final task1 = DownloadTask(
        url: 'url',
        filename: defaultFilename,
        urlQueryParameters: {'param1': '1', 'param2': 'with space'});
    expect(task1.url, equals('url?param1=1&param2=with space'));
    final task2 = DownloadTask(
        url: 'url?param0=0',
        filename: defaultFilename,
        urlQueryParameters: {'param1': '1', 'param2': 'with space'});
    expect(task2.url, equals('url?param0=0&param1=1&param2=with space'));
    final task4 =
        DownloadTask(url: urlWithContentLength, filename: defaultFilename);
    expect(task4.url, equals(urlWithContentLength));
  });

  test('downloadTask filename', () {
    final task0 = DownloadTask(url: workingUrl);
    expect(task0.filename.isNotEmpty, isTrue);
    final task1 = DownloadTask(url: workingUrl, filename: defaultFilename);
    expect(task1.filename, equals(defaultFilename));
    expect(
        () =>
            DownloadTask(url: workingUrl, filename: 'somedir/$defaultFilename'),
        throwsArgumentError);
  });

  test('downloadTask hasFilename and ?', () {
    final task0 = DownloadTask(url: workingUrl);
    expect(task0.hasFilename, isTrue);
    final task1 = DownloadTask(url: workingUrl, filename: '?');
    expect(task1.hasFilename, isFalse);
  });

  test('downloadTask directory', () {
    final task0 = DownloadTask(url: workingUrl);
    expect(task0.directory.isEmpty, isTrue);
    final task1 = DownloadTask(url: workingUrl, directory: 'testDir');
    expect(task1.directory, equals('testDir'));
    final task2 = DownloadTask(url: workingUrl, directory: '/testDir');
    expect(task2.directory, equals('testDir'));
    final task3 = DownloadTask(url: workingUrl, directory: '/');
    expect(task3.directory, equals(''));
  });

  test('cookieHeader selection', () async {
    // test that the right cookies are included/excluded, based on cookie
    // settings and the url
    var url = 'https://www.google.com/test/something';
    var c = Cookie('name', 'value');
    expect(Request.cookieHeader([c], url), equals({'Cookie': 'name=value'}));
    var c2 = Cookie('name2', 'value2');
    expect(Request.cookieHeader([c, c2], url),
        equals({'Cookie': 'name=value; name2=value2'}));
    var c3 = Cookie('', 'value3');
    expect(Request.cookieHeader([c, c2, c3], url),
        equals({'Cookie': 'name=value; name2=value2; value3'}));
    c.maxAge = 0;
    expect(Request.cookieHeader([c], url), equals({}));
    c.maxAge = 1;
    expect(Request.cookieHeader([c], url), equals({'Cookie': 'name=value'}));
    c.domain = 'notGoogle';
    expect(Request.cookieHeader([c], url), equals({}));
    c.domain = 'google.com';
    expect(Request.cookieHeader([c], url), equals({'Cookie': 'name=value'}));
    c.path = '/notTest';
    expect(Request.cookieHeader([c], url), equals({}));
    c.path = '/test';
    expect(Request.cookieHeader([c], url), equals({'Cookie': 'name=value'}));
    c.path = '/';
    expect(Request.cookieHeader([c], 'https://google.com'),
        equals({'Cookie': 'name=value'}));
    c.expires = DateTime.now().subtract(const Duration(seconds: 1));
    expect(Request.cookieHeader([c], url), equals({}));
    c.expires = DateTime.now().add(const Duration(seconds: 1));
    expect(Request.cookieHeader([c], url), equals({'Cookie': 'name=value'}));
    await Future.delayed(const Duration(milliseconds: 1100)); // let expire
    expect(Request.cookieHeader([c], url), equals({}));
    c.expires = null;
    c.secure = true;
    expect(Request.cookieHeader([c], 'http://www.google.com/test/something'),
        equals({}));
    expect(Request.cookieHeader([c], url), equals({'Cookie': 'name=value'}));
    // test creation of a task with this
    final task = DownloadTask(url: url, headers: {
      'Auth': 'Token',
      ...Request.cookieHeader([c, c2, c3], url)
    });
    expect(
        task.headers,
        equals(
            {'Auth': 'Token', 'Cookie': 'name=value; name2=value2; value3'}));
    // test with cookies as a String
    const setCookie = 'name=value,name2=value2';
    expect(Request.cookieHeader(setCookie, url),
        equals({'Cookie': 'name=value; name2=value2'}));
    // test with cookies as an illegal type
    expect(() => Request.cookieHeader(1, url), throwsArgumentError);
  });

  test('cookiesFromSetCookie', () {
    // based on https://github.com/dart-lang/http/pull/688/files
    const setCookie =
        'AWSALB=AWSALB_TEST; Expires=Tue, 26 Apr 2022 00:26:55 GMT; Path=/,AWSALBCORS=AWSALBCORS_TEST; Expires=Tue, 26 Apr 2022 00:26:55 GMT; Path=/; SameSite=None; Secure,jwt_token=JWT_TEST; Domain=.test.com; Max-Age=31536000; Path=/; expires=Wed, 19-Apr-2023 00:26:55 GMT; SameSite=lax; Secure,csrf_token=CSRF_TOKEN_TEST_1; Domain=.test.com; Max-Age=31536000; Path=/; expires=Wed, 19-Apr-2023 00:26:55 GMT,csrf_token=CSRF_TOKEN_TEST_2; Domain=.test.com; Max-Age=31536000; Path=/; expires=Wed, 19-Apr-2023 00:26:55 GMT,wuuid=WUUID_TEST';
    final cookies = Request.cookiesFromSetCookie(setCookie);
    for (final cookie in cookies) {
      expect(
          cookie.name,
          anyOf([
            'AWSALB',
            'AWSALBCORS',
            'jwt_token',
            'csrf_token',
            'wuuid',
            'csrf_token'
          ]));
      expect(
          cookie.value,
          anyOf([
            'AWSALB_TEST',
            'AWSALBCORS_TEST',
            'JWT_TEST',
            'CSRF_TOKEN_TEST_1',
            'CSRF_TOKEN_TEST_2',
            'WUUID_TEST'
          ]));
    }
  });

  test('cookies from real result', () {
    const setCookie =
        '1P_JAR=2023-12-07-04; expires=Sat, 06-Jan-2024 04:35:39 GMT; path=/; domain=.google.com; Secure,AEC=Ackid1SEIH1DSwhiGIkMBIfXQvDRUa7r-KDyUd6VRiIy7ymCzAdeQhHrEw; expires=Tue, 04-Jun-2024 04:35:39 GMT; path=/; domain=.google.com; Secure; HttpOnly; SameSite=lax,NID=511=gw-jjbhBPUTQAaqPg8wu3JI8t_Q_cxjtFAlHVgmq4qgEZF4hJuRLqnVVV13rQawScVpvgn-QVy0YFaJ9eS7Y9vXWduG33xRARAH6SbZ23HAzhQRierJWVzdyurmrukkzJJZjgUC5gPhqxWS4NgewajCbOkGItfegf5_ukstq5RA; expires=Fri, 07-Jun-2024 04:35:39 GMT; path=/; domain=.google.com; HttpOnly';
    final cookies = Request.cookiesFromSetCookie(setCookie);
    expect(cookies.length, equals(3));
    expect(cookies.first.name, equals('1P_JAR'));
    expect(cookies.first.value, equals('2023-12-07-04'));
    expect(cookies.first.expires, equals(DateTime.utc(2024, 1, 6, 4, 35, 39)));
    expect(cookies.first.path, equals('/'));
    expect(cookies.first.domain, equals('.google.com'));
  });
}
