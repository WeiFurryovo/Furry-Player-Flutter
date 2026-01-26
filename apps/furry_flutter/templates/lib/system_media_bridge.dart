import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:smtc_windows/smtc_windows.dart';

class SystemMediaMetadata {
  final String title;
  final String artist;
  final String album;
  final Uri? artUri;
  final Duration? duration;

  const SystemMediaMetadata({
    required this.title,
    required this.artist,
    required this.album,
    required this.artUri,
    required this.duration,
  });
}

class SystemMediaBridge {
  SystemMediaBridge(this._player);

  final AudioPlayer _player;

  final List<StreamSubscription<dynamic>> _subs =
      <StreamSubscription<dynamic>>[];
  _WindowsSmtc? _windows;
  _LinuxMpris? _linux;

  Future<void> init() async {
    if (kIsWeb) return;
    if (Platform.isWindows) {
      _windows = await _WindowsSmtc.create(_player);
      return;
    }
    if (Platform.isLinux) {
      _linux = await _LinuxMpris.create(_player);
      return;
    }
  }

  Future<void> setMetadata(SystemMediaMetadata meta) async {
    await _windows?.setMetadata(meta);
    await _linux?.setMetadata(meta);
  }

  void bindQueueControls({
    Future<void> Function()? onNext,
    Future<void> Function()? onPrevious,
  }) {
    _windows?.bindQueueControls(onNext: onNext, onPrevious: onPrevious);
    _linux?.bindQueueControls(onNext: onNext, onPrevious: onPrevious);
  }

  Future<void> setQueueAvailability({
    required bool canGoNext,
    required bool canGoPrevious,
  }) async {
    await _windows?.setQueueAvailability(
      canGoNext: canGoNext,
      canGoPrevious: canGoPrevious,
    );
    await _linux?.setQueueAvailability(
      canGoNext: canGoNext,
      canGoPrevious: canGoPrevious,
    );
  }

  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _windows?.dispose();
    await _linux?.dispose();
  }
}

class _WindowsSmtc {
  _WindowsSmtc._(this._player, this._smtc);

  final AudioPlayer _player;
  final SMTCWindows _smtc;
  final List<StreamSubscription<dynamic>> _subs =
      <StreamSubscription<dynamic>>[];
  Future<void> Function()? _onNext;
  Future<void> Function()? _onPrevious;

  static Future<_WindowsSmtc> create(AudioPlayer player) async {
    await SMTCWindows.initialize();
    final smtc = SMTCWindows(
      config: const SMTCConfig(
        playEnabled: true,
        pauseEnabled: true,
        nextEnabled: false,
        prevEnabled: false,
        stopEnabled: false,
        fastForwardEnabled: false,
        rewindEnabled: false,
      ),
    );

    final inst = _WindowsSmtc._(player, smtc);
    inst._wire();
    return inst;
  }

  void _wire() {
    _subs.add(_player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        _smtc.setPlaybackStatus(PlaybackStatus.stopped);
        return;
      }
      if (state.playing) {
        _smtc.setPlaybackStatus(PlaybackStatus.playing);
      } else {
        _smtc.setPlaybackStatus(PlaybackStatus.paused);
      }
    }));

    _subs.add(_player.durationStream.listen((d) {
      if (d == null) return;
      _smtc.setStartTime(Duration.zero);
      _smtc.setEndTime(d);
    }));

    _subs.add(_player.positionStream.listen((p) {
      _smtc.setPosition(p);
    }));

    _subs.add(_smtc.buttonPressStream.listen((btn) async {
      switch (btn) {
        case PressedButton.play:
          await _player.play();
          break;
        case PressedButton.pause:
          await _player.pause();
          break;
        case PressedButton.stop:
          break;
        case PressedButton.next:
          final fn = _onNext;
          if (fn != null) await fn();
          break;
        case PressedButton.previous:
          final fn = _onPrevious;
          if (fn != null) await fn();
          break;
        case PressedButton.fastForward:
        case PressedButton.rewind:
        case PressedButton.record:
        case PressedButton.channelUp:
        case PressedButton.channelDown:
          break;
      }
    }));
  }

  void bindQueueControls({
    Future<void> Function()? onNext,
    Future<void> Function()? onPrevious,
  }) {
    _onNext = onNext;
    _onPrevious = onPrevious;
  }

  Future<void> setQueueAvailability({
    required bool canGoNext,
    required bool canGoPrevious,
  }) async {
    await _smtc.setIsNextEnabled(canGoNext);
    await _smtc.setIsPrevEnabled(canGoPrevious);
  }

  Future<void> setMetadata(SystemMediaMetadata meta) async {
    await _smtc.updateMetadata(
      MusicMetadata(
        title: meta.title,
        artist: meta.artist,
        album: meta.album,
        thumbnail: meta.artUri?.toString(),
      ),
    );
    final d = meta.duration;
    if (d != null && d > Duration.zero) {
      await _smtc.updateTimeline(
        PlaybackTimeline(
          positionMs: _player.position.inMilliseconds,
          startTimeMs: 0,
          endTimeMs: d.inMilliseconds,
          minSeekTimeMs: 0,
          maxSeekTimeMs: d.inMilliseconds,
        ),
      );
    }
  }

  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _smtc.dispose();
  }
}

class _LinuxMpris {
  _LinuxMpris._(this._player, this._client, this._obj);

  final AudioPlayer _player;
  final DBusClient _client;
  final _MprisObject _obj;
  final List<StreamSubscription<dynamic>> _subs =
      <StreamSubscription<dynamic>>[];

  static const _busName = 'org.mpris.MediaPlayer2.furry_flutter_app';
  static final _objectPath = DBusObjectPath('/org/mpris/MediaPlayer2');

  static Future<_LinuxMpris> create(AudioPlayer player) async {
    final client = DBusClient.session();
    await client.requestName(_busName, flags: {DBusRequestNameFlag.doNotQueue});
    final obj = _MprisObject(_objectPath, player);
    await client.registerObject(obj);
    obj.client = client;

    final inst = _LinuxMpris._(player, client, obj);
    inst._wire();
    return inst;
  }

  void _wire() {
    _subs.add(_player.playerStateStream.listen((state) {
      _obj.updatePlayback(state);
    }));
    _subs.add(_player.durationStream.listen((d) {
      _obj.updateDuration(d);
    }));
    _subs.add(_player.positionStream.listen((p) {
      _obj.updatePosition(p);
    }));
  }

  Future<void> setMetadata(SystemMediaMetadata meta) => _obj.setMetadata(meta);

  void bindQueueControls({
    Future<void> Function()? onNext,
    Future<void> Function()? onPrevious,
  }) {
    _obj.bindQueueControls(onNext: onNext, onPrevious: onPrevious);
  }

  Future<void> setQueueAvailability({
    required bool canGoNext,
    required bool canGoPrevious,
  }) =>
      _obj.setQueueAvailability(
        canGoNext: canGoNext,
        canGoPrevious: canGoPrevious,
      );

  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _client.unregisterObject(_obj);
    await _client.releaseName(_busName);
    await _client.close();
  }
}

class _MprisObject extends DBusObject {
  _MprisObject(super.path, this._player);

  final AudioPlayer _player;

  String _playbackStatus = 'Stopped';
  bool _canControl = true;
  bool _canGoNext = false;
  bool _canGoPrevious = false;
  Duration? _duration;
  Duration _position = Duration.zero;
  Map<String, DBusValue> _metadata = <String, DBusValue>{};

  Future<void> Function()? _onNext;
  Future<void> Function()? _onPrevious;

  Future<void> setMetadata(SystemMediaMetadata meta) async {
    _duration = meta.duration;
    _metadata = <String, DBusValue>{
      'mpris:trackid': DBusObjectPath('/org/mpris/MediaPlayer2/track/0'),
      'xesam:title': DBusString(meta.title),
      'xesam:artist':
          DBusArray(DBusSignature('s'), <DBusValue>[DBusString(meta.artist)]),
      'xesam:album': DBusString(meta.album),
      if (_duration != null)
        'mpris:length': DBusInt64(_duration!.inMicroseconds),
      if (meta.artUri != null)
        'mpris:artUrl': DBusString(meta.artUri.toString()),
    };
    await emitPropertiesChanged(
      'org.mpris.MediaPlayer2.Player',
      changedProperties: <String, DBusValue>{
        'Metadata': DBusDict.stringVariant(_metadata),
      },
    );
  }

  void bindQueueControls({
    Future<void> Function()? onNext,
    Future<void> Function()? onPrevious,
  }) {
    _onNext = onNext;
    _onPrevious = onPrevious;
  }

  Future<void> setQueueAvailability({
    required bool canGoNext,
    required bool canGoPrevious,
  }) async {
    if (_canGoNext == canGoNext && _canGoPrevious == canGoPrevious) return;
    _canGoNext = canGoNext;
    _canGoPrevious = canGoPrevious;
    await emitPropertiesChanged(
      'org.mpris.MediaPlayer2.Player',
      changedProperties: <String, DBusValue>{
        'CanGoNext': DBusBoolean(_canGoNext),
        'CanGoPrevious': DBusBoolean(_canGoPrevious),
      },
    );
  }

  void updateDuration(Duration? d) {
    _duration = d;
    if (d == null) return;
    emitPropertiesChanged(
      'org.mpris.MediaPlayer2.Player',
      changedProperties: <String, DBusValue>{
        'Metadata': DBusDict.stringVariant(<String, DBusValue>{
          ..._metadata,
          'mpris:length': DBusInt64(d.inMicroseconds),
        }),
      },
    );
  }

  void updatePosition(Duration p) {
    _position = p;
  }

  void updatePlayback(PlayerState state) {
    final next = state.playing ? 'Playing' : 'Paused';
    if (state.processingState == ProcessingState.idle ||
        state.processingState == ProcessingState.completed) {
      _playbackStatus = 'Stopped';
    } else {
      _playbackStatus = next;
    }
    emitPropertiesChanged(
      'org.mpris.MediaPlayer2.Player',
      changedProperties: <String, DBusValue>{
        'PlaybackStatus': DBusString(_playbackStatus),
      },
    );
  }

  @override
  List<DBusIntrospectInterface> introspect() {
    DBusIntrospectMethod m(String name,
            {List<DBusIntrospectArgument> args = const []}) =>
        DBusIntrospectMethod(name, args: args);

    DBusIntrospectProperty p(
            String name, String sig, DBusPropertyAccess access) =>
        DBusIntrospectProperty(name, DBusSignature(sig), access: access);

    return <DBusIntrospectInterface>[
      DBusIntrospectInterface(
        'org.mpris.MediaPlayer2',
        methods: <DBusIntrospectMethod>[m('Raise'), m('Quit')],
        properties: <DBusIntrospectProperty>[
          p('CanQuit', 'b', DBusPropertyAccess.read),
          p('CanRaise', 'b', DBusPropertyAccess.read),
          p('HasTrackList', 'b', DBusPropertyAccess.read),
          p('Identity', 's', DBusPropertyAccess.read),
          p('DesktopEntry', 's', DBusPropertyAccess.read),
          p('SupportedUriSchemes', 'as', DBusPropertyAccess.read),
          p('SupportedMimeTypes', 'as', DBusPropertyAccess.read),
        ],
      ),
      DBusIntrospectInterface(
        'org.mpris.MediaPlayer2.Player',
        methods: <DBusIntrospectMethod>[
          m('Next'),
          m('Previous'),
          m('Pause'),
          m('PlayPause'),
          m('Stop'),
          m('Play'),
          m(
            'Seek',
            args: <DBusIntrospectArgument>[
              DBusIntrospectArgument(
                  DBusSignature('x'), DBusArgumentDirection.in_,
                  name: 'Offset'),
            ],
          ),
          m(
            'SetPosition',
            args: <DBusIntrospectArgument>[
              DBusIntrospectArgument(
                  DBusSignature('o'), DBusArgumentDirection.in_,
                  name: 'TrackId'),
              DBusIntrospectArgument(
                  DBusSignature('x'), DBusArgumentDirection.in_,
                  name: 'Position'),
            ],
          ),
          m(
            'OpenUri',
            args: <DBusIntrospectArgument>[
              DBusIntrospectArgument(
                  DBusSignature('s'), DBusArgumentDirection.in_,
                  name: 'Uri'),
            ],
          ),
        ],
        signals: <DBusIntrospectSignal>[
          DBusIntrospectSignal(
            'Seeked',
            args: <DBusIntrospectArgument>[
              DBusIntrospectArgument(
                  DBusSignature('x'), DBusArgumentDirection.out,
                  name: 'Position'),
            ],
          ),
        ],
        properties: <DBusIntrospectProperty>[
          p('PlaybackStatus', 's', DBusPropertyAccess.read),
          p('LoopStatus', 's', DBusPropertyAccess.readwrite),
          p('Rate', 'd', DBusPropertyAccess.readwrite),
          p('Shuffle', 'b', DBusPropertyAccess.readwrite),
          p('Metadata', 'a{sv}', DBusPropertyAccess.read),
          p('Volume', 'd', DBusPropertyAccess.readwrite),
          p('Position', 'x', DBusPropertyAccess.read),
          p('MinimumRate', 'd', DBusPropertyAccess.read),
          p('MaximumRate', 'd', DBusPropertyAccess.read),
          p('CanGoNext', 'b', DBusPropertyAccess.read),
          p('CanGoPrevious', 'b', DBusPropertyAccess.read),
          p('CanPlay', 'b', DBusPropertyAccess.read),
          p('CanPause', 'b', DBusPropertyAccess.read),
          p('CanSeek', 'b', DBusPropertyAccess.read),
          p('CanControl', 'b', DBusPropertyAccess.read),
        ],
      ),
    ];
  }

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    final iface = methodCall.interface;
    final name = methodCall.name;

    if (iface == 'org.mpris.MediaPlayer2') {
      switch (name) {
        case 'Raise':
          return DBusMethodSuccessResponse();
        case 'Quit':
          return DBusMethodSuccessResponse();
      }
    }

    if (iface == 'org.mpris.MediaPlayer2.Player') {
      switch (name) {
        case 'Play':
          await _player.play();
          return DBusMethodSuccessResponse();
        case 'Pause':
          await _player.pause();
          return DBusMethodSuccessResponse();
        case 'PlayPause':
          if (_player.playing) {
            await _player.pause();
          } else {
            await _player.play();
          }
          return DBusMethodSuccessResponse();
        case 'Stop':
          await _player.stop();
          return DBusMethodSuccessResponse();
        case 'Seek':
          final offsetUs = (methodCall.values.first as DBusInt64).value;
          final target = _position + Duration(microseconds: offsetUs);
          await _player.seek(target < Duration.zero ? Duration.zero : target);
          await emitSignal('org.mpris.MediaPlayer2.Player', 'Seeked',
              [DBusInt64(_player.position.inMicroseconds)]);
          return DBusMethodSuccessResponse();
        case 'SetPosition':
          final posUs = (methodCall.values[1] as DBusInt64).value;
          await _player.seek(Duration(microseconds: posUs));
          await emitSignal('org.mpris.MediaPlayer2.Player', 'Seeked',
              [DBusInt64(_player.position.inMicroseconds)]);
          return DBusMethodSuccessResponse();
        case 'Next':
          final fn = _onNext;
          if (fn != null) await fn();
          return DBusMethodSuccessResponse();
        case 'Previous':
          final fn = _onPrevious;
          if (fn != null) await fn();
          return DBusMethodSuccessResponse();
        case 'OpenUri':
          return DBusMethodSuccessResponse();
      }
    }

    return DBusMethodErrorResponse.unknownMethod();
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    if (interface == 'org.mpris.MediaPlayer2') {
      switch (name) {
        case 'CanQuit':
          return DBusGetPropertyResponse(DBusBoolean(false));
        case 'CanRaise':
          return DBusGetPropertyResponse(DBusBoolean(true));
        case 'HasTrackList':
          return DBusGetPropertyResponse(DBusBoolean(false));
        case 'Identity':
          return DBusGetPropertyResponse(DBusString('Furry Player'));
        case 'DesktopEntry':
          return DBusGetPropertyResponse(DBusString('furry_flutter_app'));
        case 'SupportedUriSchemes':
          return DBusGetPropertyResponse(
              DBusArray(DBusSignature('s'), <DBusValue>[DBusString('file')]));
        case 'SupportedMimeTypes':
          return DBusGetPropertyResponse(
              DBusArray(DBusSignature('s'), <DBusValue>[]));
      }
    }

    if (interface == 'org.mpris.MediaPlayer2.Player') {
      switch (name) {
        case 'PlaybackStatus':
          return DBusGetPropertyResponse(DBusString(_playbackStatus));
        case 'LoopStatus':
          return DBusGetPropertyResponse(DBusString('None'));
        case 'Rate':
          return DBusGetPropertyResponse(DBusDouble(1.0));
        case 'Shuffle':
          return DBusGetPropertyResponse(DBusBoolean(false));
        case 'Metadata':
          return DBusGetPropertyResponse(DBusDict.stringVariant(_metadata));
        case 'Volume':
          return DBusGetPropertyResponse(DBusDouble(1.0));
        case 'Position':
          return DBusGetPropertyResponse(DBusInt64(_position.inMicroseconds));
        case 'MinimumRate':
          return DBusGetPropertyResponse(DBusDouble(1.0));
        case 'MaximumRate':
          return DBusGetPropertyResponse(DBusDouble(1.0));
        case 'CanGoNext':
          return DBusGetPropertyResponse(DBusBoolean(_canGoNext));
        case 'CanGoPrevious':
          return DBusGetPropertyResponse(DBusBoolean(_canGoPrevious));
        case 'CanPlay':
          return DBusGetPropertyResponse(DBusBoolean(true));
        case 'CanPause':
          return DBusGetPropertyResponse(DBusBoolean(true));
        case 'CanSeek':
          return DBusGetPropertyResponse(DBusBoolean(true));
        case 'CanControl':
          return DBusGetPropertyResponse(DBusBoolean(_canControl));
      }
    }

    return DBusMethodErrorResponse.unknownProperty();
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async {
    if (interface == 'org.mpris.MediaPlayer2') {
      return DBusGetAllPropertiesResponse(<String, DBusValue>{
        'CanQuit': DBusBoolean(false),
        'CanRaise': DBusBoolean(true),
        'HasTrackList': DBusBoolean(false),
        'Identity': DBusString('Furry Player'),
        'DesktopEntry': DBusString('furry_flutter_app'),
        'SupportedUriSchemes':
            DBusArray(DBusSignature('s'), <DBusValue>[DBusString('file')]),
        'SupportedMimeTypes': DBusArray(DBusSignature('s'), <DBusValue>[]),
      });
    }
    if (interface == 'org.mpris.MediaPlayer2.Player') {
      return DBusGetAllPropertiesResponse(<String, DBusValue>{
        'PlaybackStatus': DBusString(_playbackStatus),
        'LoopStatus': DBusString('None'),
        'Rate': DBusDouble(1.0),
        'Shuffle': DBusBoolean(false),
        'Metadata': DBusDict.stringVariant(_metadata),
        'Volume': DBusDouble(1.0),
        'Position': DBusInt64(_position.inMicroseconds),
        'MinimumRate': DBusDouble(1.0),
        'MaximumRate': DBusDouble(1.0),
        'CanGoNext': DBusBoolean(_canGoNext),
        'CanGoPrevious': DBusBoolean(_canGoPrevious),
        'CanPlay': DBusBoolean(true),
        'CanPause': DBusBoolean(true),
        'CanSeek': DBusBoolean(true),
        'CanControl': DBusBoolean(_canControl),
      });
    }
    return DBusGetAllPropertiesResponse({});
  }
}
