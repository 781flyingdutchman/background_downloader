// ignore_for_file: avoid_print, empty_catches

import 'dart:convert';

import 'package:background_downloader/background_downloader.dart';
import 'package:background_downloader/src/base_downloader.dart';
import 'package:background_downloader/src/chunk.dart';
import 'package:background_downloader/src/desktop/parallel_download_isolate.dart';
import 'package:flutter_test/flutter_test.dart';

const urlWithContentLength = 'https://storage.googleapis'
    '.com/approachcharts/test/5MB-test.ZIP';
const urlWithContentLengthFileSize = 6207471;

void main() {
  test('createChunks', () {
    // one url, one chunk
    var task = ParallelDownloadTask(url: urlWithContentLength);
    expect(
        () => createChunks(task, {}), throwsA(const TypeMatcher<StateError>()));
    expect(() => createChunks(task, {'content-length': '100'}),
        throwsA(const TypeMatcher<StateError>()));
    expect(() => createChunks(task, {'accept-ranges': 'bytes'}),
        throwsA(const TypeMatcher<StateError>()));
    expect(
        () => createChunks(
            task, {'content-length': '-1', 'accept-ranges': 'bytes'}),
        throwsA(const TypeMatcher<StateError>()));
    var chunks =
        createChunks(task, {'content-length': '100', 'accept-ranges': 'bytes'});
    expect(chunks.length, equals(1));
    var chunk = chunks.first;
    expect(chunk.url, equals(task.url));
    expect(chunk.filename.isNotEmpty, isTrue);
    expect(chunk.from, equals(0));
    expect(chunk.to, equals(99));
    // one url, three chunks
    task = ParallelDownloadTask(url: urlWithContentLength, chunks: 3);
    chunks =
        createChunks(task, {'content-length': '100', 'accept-ranges': 'bytes'});
    expect(chunks.length, equals(3));
    chunk = chunks.first;
    expect(chunk.url, equals(task.url));
    expect(chunk.filename.isNotEmpty, isTrue);
    expect(chunk.from, equals(0));
    expect(chunk.to, equals(33));
    expect(chunk.parentTaskId, equals(task.taskId));
    expect(chunk.task.metaData, equals(task.taskId));
    expect(chunk.task.group, equals(BaseDownloader.chunkGroup));
    chunk = chunks[1];
    expect(chunk.url, equals(task.url));
    expect(chunk.filename.isNotEmpty, isTrue);
    expect(chunk.from, equals(34));
    expect(chunk.to, equals(67));
    chunk = chunks[2];
    expect(chunk.url, equals(task.url));
    expect(chunk.filename.isNotEmpty, isTrue);
    expect(chunk.from, equals(68));
    expect(chunk.to, equals(99));
    // two urls, two chunks
    task = ParallelDownloadTask(
        url: [urlWithContentLength, urlWithContentLength], chunks: 2);
    chunks =
        createChunks(task, {'content-length': '100', 'accept-ranges': 'bytes'});
    expect(chunks.length, equals(4));
    chunk = chunks.first;
    expect(chunk.url, equals(task.urls.first));
    expect(chunk.filename.isNotEmpty, isTrue);
    expect(chunk.from, equals(0));
    expect(chunk.to, equals(24));
    chunk = chunks[1];
    expect(chunk.url, equals(task.urls.last));
    expect(chunk.filename.isNotEmpty, isTrue);
    expect(chunk.from, equals(25));
    expect(chunk.to, equals(49));
    chunk = chunks[2];
    expect(chunk.url, equals(task.urls.first));
    expect(chunk.filename.isNotEmpty, isTrue);
    expect(chunk.from, equals(50));
    expect(chunk.to, equals(74));
    chunk = chunks[3];
    expect(chunk.url, equals(task.urls.last));
    expect(chunk.filename.isNotEmpty, isTrue);
    expect(chunk.from, equals(75));
    expect(chunk.to, equals(99));
  });

  test('updates', () {
    var task = ParallelDownloadTask(url: urlWithContentLength, chunks: 3);
    parentTask = task;
    chunks = createChunks(task, {
      'content-length': urlWithContentLengthFileSize.toString(),
      'accept-ranges': 'bytes'
    });
    expect(chunks.length, equals(3));
    expect(chunks.first.size, equals(2069156));
    // check progress update
    expect(parentTaskProgress().progress, equals(0.0));
    // fake 50% progress on first chunk (of 3)
    final progressUpdate =
        updateChunkProgress(TaskProgressUpdate(chunks.first.task, 0.5));
    expect(progressUpdate?.progress, equals(0.5 / 3));
    // check status update towards complete
    expect(parentTaskStatusUpdate(), isNull);
    expect(
        updateChunkStatus(
            TaskStatusUpdate(chunks.first.task, TaskStatus.complete)),
        isNull);
    expect(
        updateChunkStatus(
            TaskStatusUpdate(chunks.last.task, TaskStatus.complete)),
        isNull);
    expect(
        updateChunkStatus(TaskStatusUpdate(chunks[1].task, TaskStatus.complete))
            ?.status,
        equals(TaskStatus.complete));
    // check failed
    for (final chunk in chunks) {
      updateChunkStatus(TaskStatusUpdate(chunk.task, TaskStatus.failed));
    }
    expect(parentTaskStatusUpdate()?.status, equals(TaskStatus.failed));
// check notFound
    for (final chunk in chunks) {
      updateChunkStatus(TaskStatusUpdate(chunk.task, TaskStatus.notFound));
    }
    expect(parentTaskStatusUpdate()?.status, equals(TaskStatus.notFound));
  });

  test('json chunks', () {
    var task = ParallelDownloadTask(url: urlWithContentLength, chunks: 3);
    chunks = createChunks(task, {
      'content-length': urlWithContentLengthFileSize.toString(),
      'accept-ranges': 'bytes'
    });
    final chunksJson = jsonEncode(chunks);
    final List<Chunk> decodedChunks = List.from(jsonDecode(chunksJson, reviver: Chunk.reviver));
    for (var i = 0; i < chunks.length; i++) {
      expect(chunks[i].parentTaskId, equals(decodedChunks[i].parentTaskId));
      expect(chunks[i].url, equals(decodedChunks[i].url));
      expect(chunks[i].filename, equals(decodedChunks[i].filename));
      expect(chunks[i].from, equals(decodedChunks[i].from));
      expect(chunks[i].to, equals(decodedChunks[i].to));
      expect(chunks[i].task, equals(decodedChunks[i].task));
      expect(chunks[i].task.metaData, equals(decodedChunks[i].task.metaData));
      expect(chunks[i].statusUpdate.status, equals(decodedChunks[i].statusUpdate.status));
      expect(chunks[i].progressUpdate.progress, equals(decodedChunks[i].progressUpdate.progress));
    }
  });

}
