part of '../main.dart';

String _fmtBytes(int bytes) {
  const kb = 1024;
  const mb = 1024 * 1024;
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(1)} KB';
  return '$bytes B';
}

PageRoute<T> _expressivePageRoute<T>(Widget page) {
  return PageRouteBuilder<T>(
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionDuration: const Duration(milliseconds: 260),
    reverseTransitionDuration: const Duration(milliseconds: 220),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      final offset = Tween<Offset>(
        begin: const Offset(0.06, 0),
        end: Offset.zero,
      ).animate(curved);
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(position: offset, child: child),
      );
    },
  );
}

String _albumHeroTag(_AlbumGroup album) {
  return 'album_${album.artist.toLowerCase()}|${album.album.toLowerCase()}';
}

int _libraryLoadingPlaceholderCount(_LibraryView view) {
  switch (view) {
    case _LibraryView.tracks:
      return 6;
    case _LibraryView.albums:
      return 4;
    case _LibraryView.artists:
      return 5;
    case _LibraryView.queue:
      return 5;
  }
}

@visibleForTesting
int libraryLoadingPlaceholderCountForTest(int viewIndex) {
  return _libraryLoadingPlaceholderCount(_LibraryView.values[viewIndex]);
}

String _nowPlayingHeroTag(String sourcePath) {
  // Keep it stable and reasonably short; Hero tags can be any object, but we
  // prefer a string for easier debugging.
  return 'np_${sourcePath.hashCode}';
}
