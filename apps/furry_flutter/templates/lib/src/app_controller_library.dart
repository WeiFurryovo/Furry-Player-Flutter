part of '../main.dart';

class _TrackEntryCacheEntry {
  final DateTime modified;
  final int bytes;
  final _TrackEntry track;

  const _TrackEntryCacheEntry({
    required this.modified,
    required this.bytes,
    required this.track,
  });
}

class _LibraryIndexCacheEntry {
  final int signature;
  final _LibraryIndex index;

  const _LibraryIndexCacheEntry({
    required this.signature,
    required this.index,
  });
}

class _FileStatEntry {
  final File file;
  final FileStat stat;

  const _FileStatEntry({
    required this.file,
    required this.stat,
  });
}

class _PendingTrackEntry {
  final int index;
  final File file;
  final DateTime modified;
  final int bytes;

  const _PendingTrackEntry({
    required this.index,
    required this.file,
    required this.modified,
    required this.bytes,
  });
}

extension _AppControllerLibraryExtension on _AppController {
  int _fileStatesSignature(List<_FileStatEntry> fileStates) {
    return Object.hash(
      fileStates.length,
      Object.hashAll(fileStates.map((entry) {
        return Object.hash(
          entry.file.path,
          entry.stat.modified.microsecondsSinceEpoch,
          entry.stat.size,
        );
      })),
    );
  }

  Future<List<_FileStatEntry>> _statFilesInOrder(
    List<File> files, {
    required int concurrency,
    void Function(File file, Object error, StackTrace stackTrace)? onError,
  }) async {
    if (files.isEmpty) return const [];

    final slots = List<_FileStatEntry?>.filled(files.length, null);
    var cursor = 0;
    final workerCount = files.length < concurrency ? files.length : concurrency;

    Future<void> worker() async {
      while (true) {
        final index = cursor;
        if (index >= files.length) return;
        cursor = index + 1;

        final file = files[index];
        try {
          final stat = await file.stat();
          if (stat.type == FileSystemEntityType.file) {
            slots[index] = _FileStatEntry(file: file, stat: stat);
          }
        } catch (e, st) {
          onError?.call(file, e, st);
        }
      }
    }

    await Future.wait(
      List<Future<void>>.generate(workerCount, (_) => worker()),
    );

    return slots.whereType<_FileStatEntry>().toList(growable: false);
  }

  Future<void> refreshOutputs() async {
    final refreshToken = _outputsRefreshGate.begin();

    bool isStale() => !_outputsRefreshGate.isCurrent(refreshToken);

    final outDir = await outputsDir();
    if (isStale()) return;

    final files = (await _listFiles(outDir))
        .where((f) => p.extension(f.path).toLowerCase() == '.furry')
        .toList(growable: false);
    final fileStates = await _statFilesInOrder(
      files,
      concurrency: _AppController._ioWorkerCount,
    )
      ..sort((a, b) => b.stat.modified.compareTo(a.stat.modified));

    if (isStale()) return;

    furryOutputs.value =
        fileStates.map((entry) => entry.file).toList(growable: false);
    furryOutputsSignature.value = _fileStatesSignature(fileStates);
  }

  Future<_LibraryIndex> buildLibraryIndex(List<File> files) async {
    final buildToken = _libraryBuildGate.begin();

    bool isStale() => !_libraryBuildGate.isCurrent(buildToken);

    _LibraryIndex cachedOrEmpty() {
      final cached = _libraryIndexCache;
      if (cached != null) return cached.index;
      return _AppController._emptyLibraryIndex;
    }

    final states = await _statFilesInOrder(
      files,
      concurrency: _AppController._ioWorkerCount,
      onError: (file, error, stackTrace) {
        appendLog('Index stat failed: ${file.path}: $error\n$stackTrace');
      },
    );

    if (isStale()) return cachedOrEmpty();

    final signature = _fileStatesSignature(states);
    final cached = _libraryIndexCache;
    if (cached != null && cached.signature == signature) {
      return cached.index;
    }

    final activePaths = <String>{};
    final tracksByIndex = List<_TrackEntry?>.filled(states.length, null);
    final pending = <_PendingTrackEntry>[];
    for (var i = 0; i < states.length; i++) {
      if (isStale()) return cachedOrEmpty();

      final state = states[i];
      final file = state.file;
      final modified = state.stat.modified;
      final bytes = state.stat.size;
      final path = file.path;
      activePaths.add(path);

      final trackCached = _trackEntryCache[path];
      if (trackCached != null &&
          trackCached.modified == modified &&
          trackCached.bytes == bytes) {
        tracksByIndex[i] = trackCached.track;
        continue;
      }

      pending.add(_PendingTrackEntry(
        index: i,
        file: file,
        modified: modified,
        bytes: bytes,
      ));
    }

    if (pending.isNotEmpty) {
      var cursor = 0;
      final workerCount = pending.length < _AppController._metaWorkerCount
          ? pending.length
          : _AppController._metaWorkerCount;

      Future<void> worker() async {
        while (true) {
          if (isStale()) return;

          final pendingIndex = cursor;
          if (pendingIndex >= pending.length) return;
          cursor = pendingIndex + 1;

          final pendingItem = pending[pendingIndex];
          final path = pendingItem.file.path;
          try {
            final meta = await getMetaPreviewForFurry(
              pendingItem.file,
              modified: pendingItem.modified,
            );
            if (isStale()) return;

            final track = _TrackEntry(
              file: pendingItem.file,
              meta: meta,
              modified: pendingItem.modified,
              bytes: pendingItem.bytes,
            );
            _trackEntryCache[path] = _TrackEntryCacheEntry(
              modified: pendingItem.modified,
              bytes: pendingItem.bytes,
              track: track,
            );
            tracksByIndex[pendingItem.index] = track;
          } catch (e, st) {
            if (isStale()) return;

            appendLog('Index meta failed: $path: $e\n$st');
            final track = _TrackEntry(
              file: pendingItem.file,
              meta: _MetaPreview(
                title: p.basename(path),
                artist: '',
                album: '',
                subtitle: '',
                artUri: null,
                coverBytesLen: null,
              ),
              modified: pendingItem.modified,
              bytes: pendingItem.bytes,
            );
            _trackEntryCache[path] = _TrackEntryCacheEntry(
              modified: pendingItem.modified,
              bytes: pendingItem.bytes,
              track: track,
            );
            tracksByIndex[pendingItem.index] = track;
          }
        }
      }

      await Future.wait(
        List<Future<void>>.generate(workerCount, (_) => worker()),
      );
      if (isStale()) return cachedOrEmpty();
    }

    final tracks =
        tracksByIndex.whereType<_TrackEntry>().toList(growable: false);
    if (isStale()) return cachedOrEmpty();

    _trackEntryCache.removeWhere((path, _) => !activePaths.contains(path));
    _metaPreviewCache.removeWhere((path, _) => !activePaths.contains(path));

    final albumsByKey = <String, _AlbumGroup>{};
    final artistsByKey = <String, _ArtistGroup>{};

    for (final t in tracks) {
      if (isStale()) return cachedOrEmpty();

      final albumName = t.meta.album.trim();
      final artistName = t.meta.artist.trim();
      final albumKey = '${artistName.toLowerCase()}|${albumName.toLowerCase()}';
      final artistKey = artistName.toLowerCase();

      final album = albumsByKey.putIfAbsent(
        albumKey,
        () => _AlbumGroup(
          album: albumName,
          artist: artistName,
          artUri: t.meta.artUri,
        ),
      );
      album.tracks.add(t);
      album.artUri ??= t.meta.artUri;

      final artist = artistsByKey.putIfAbsent(
        artistKey,
        () => _ArtistGroup(artist: artistName, artUri: t.meta.artUri),
      );
      artist.tracks.add(t);
      artist.artUri ??= t.meta.artUri;
      artist.albumsByKey.putIfAbsent(albumKey, () => album);
    }

    final albums = albumsByKey.values.toList(growable: false)
      ..sort((a, b) => a.title.compareTo(b.title));
    final artists = artistsByKey.values.toList(growable: false)
      ..sort((a, b) => a.title.compareTo(b.title));

    for (final a in albums) {
      if (isStale()) return cachedOrEmpty();
      a.tracks.sort((x, y) => x.displayTitle.compareTo(y.displayTitle));
    }
    for (final ar in artists) {
      if (isStale()) return cachedOrEmpty();
      for (final alb in ar.albumsByKey.values) {
        alb.tracks.sort((x, y) => x.displayTitle.compareTo(y.displayTitle));
      }
    }

    final result =
        _LibraryIndex(tracks: tracks, albums: albums, artists: artists);
    if (isStale()) return cachedOrEmpty();

    _libraryIndexCache = _LibraryIndexCacheEntry(
      signature: signature,
      index: result,
    );
    return result;
  }
}
