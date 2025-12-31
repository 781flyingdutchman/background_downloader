# Server Requests & Cookies

To make a regular server request (e.g. to obtain a response from an API end point that you process directly in your app) use:
1. A `Request` object, for requests that are executed immediately, expecting an immediate return
2. A `DataTask` object, for requests that are scheduled on the background queue, similar to `DownloadTask`

## Request: immediate execution

A regular foreground request works similar to the `download` method, except you pass a `Request` object that has fewer fields than the `DownloadTask`, but is similar in structure.  You `await` the response, which will be a [Response](https://pub.dev/documentation/http/latest/http/Response-class.html) object as defined in the dart [http package](https://pub.dev/packages/http), and includes getters for the response body (as a `String` or as `UInt8List`), `statusCode` and `reasonPhrase`.

Because requests are meant to be immediate, they are not enqueued like a `Task` is, and do not allow for status/progress monitoring.

## DataTask: scheduled execution

To make a similar request using the background mechanism (e.g. if you want to wait for WiFi to be available), create and enqueue a `DataTask`.
A `DataTask` is similar to a `DownloadTask` except it:
* Does not accept file information, as there is no file involved
* Does not allow progress updates
* Accepts `post` data as a String, or
* Accepts `json` data, which will be converted to a String and posted as content type `application/json`
* Accepts `contentType` which will set the `Content-Type` header value
* Returns the server `responseBody`, `responseHeaders` and possible `taskException` in the final `TaskStatusUpdate` fields

Typically you would use `enqueue` to enqueue a `DataTask` and monitor the result using a listener or callback, but you can also use `transmit` to enqueue and wait for the final result of the `DataTask`.

# Cookies

Servers may ask you to set a cookie (via the 'Set-Cookie' header in the response), to be passed along to the next request (in the 'Cookie' header). 
This may be needed for authentication, or for session state. 

The method `Request.cookieHeader` makes it easy to insert cookies in a request. The first argument `cookies` is either a `http.Response` object (as returned by the `FileDownloader().request` method), a `List<Cookie>`, or a String value from a 'Set-Cookie' header. It returns a `{'Cookie': '...'}` header that can be added to the next request.
The second argument is the `url` you intend to use the cookies with. This is needed to filter the appropriate cookies based on domain and path.

For example:
```dart
final loginResponse = await FileDownloader()
   .request(Request(url: 'https://server.com/login', headers: {'Auth': 'Token'}));
const downloadUrl = 'https://server.com/download';
// add the cookies from the response to the task
final task = DownloadTask(url: downloadUrl, headers: {
  'Auth': 'Token',
  ...Request.cookieHeader(loginResponse, downloadUrl) // inserts the 'Cookie' header
});
```
