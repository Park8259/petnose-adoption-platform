import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PetNoseChatSmokeApp());
}

class PetNoseChatSmokeApp extends StatelessWidget {
  const PetNoseChatSmokeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'PetNose Chat Smoke',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff287067)),
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
        cardTheme: const CardThemeData(
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
        ),
      ),
      home: const FirebaseChatSmokeScreen(),
    );
  }
}

class FirebaseChatSmokeScreen extends StatefulWidget {
  const FirebaseChatSmokeScreen({super.key});

  @override
  State<FirebaseChatSmokeScreen> createState() =>
      _FirebaseChatSmokeScreenState();
}

class _FirebaseChatSmokeScreenState extends State<FirebaseChatSmokeScreen> {
  final _apiBaseUrlController =
      TextEditingController(text: 'http://localhost:8080');
  final _bearerTokenController = TextEditingController();
  final _postIdController = TextEditingController();
  final _roomIdController = TextEditingController();
  final _messageController =
      TextEditingController(text: 'Hello from Flutter visual smoke');

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
      _roomSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
      _messageSubscription;

  bool _busy = false;
  bool _firebaseReady = false;
  String? _firebaseInitError;
  String? _currentAction;
  String? _firebaseUid;
  String? _signedInUid;
  String _listenerState = 'No listener';
  Map<String, dynamic>? _roomState;
  final List<_RoomListItem> _rooms = [];
  final List<_ChatMessageItem> _messages = [];
  final List<String> _events = [];

  @override
  void initState() {
    super.initState();
    _initializeFirebase();
  }

  @override
  void dispose() {
    _roomSubscription?.cancel();
    _messageSubscription?.cancel();
    _apiBaseUrlController.dispose();
    _bearerTokenController.dispose();
    _postIdController.dispose();
    _roomIdController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _initializeFirebase() async {
    try {
      await Firebase.initializeApp();
      setState(() {
        _firebaseReady = true;
        _firebaseInitError = null;
      });
      _addEvent('Firebase client initialized.');
    } catch (error) {
      setState(() {
        _firebaseReady = false;
        _firebaseInitError = error.toString();
      });
      _addEvent('Firebase client initialization failed. Configure locally.');
    }
  }

  Future<void> _runAction(
    String label,
    Future<void> Function() action,
  ) async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _currentAction = label;
    });
    _addEvent('$label started.');
    try {
      await action();
      _addEvent('$label completed.');
    } catch (error) {
      _addEvent('$label failed: ${_safeError(error)}');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _currentAction = null;
        });
      }
    }
  }

  Future<void> _getFirebaseCustomToken() async {
    _requireFirebaseReady();
    final json = await _requestJson('POST', 'firebase/custom-token');
    final firebaseUid = json['firebase_uid']?.toString();
    final customToken = json['firebase_custom_token']?.toString();

    if (firebaseUid == null || firebaseUid.isEmpty) {
      throw const SmokeException('Response did not include firebase_uid.');
    }
    if (customToken == null || customToken.isEmpty) {
      throw const SmokeException(
        'Response did not include firebase_custom_token.',
      );
    }

    final credential =
        await FirebaseAuth.instance.signInWithCustomToken(customToken);
    setState(() {
      _firebaseUid = firebaseUid;
      _signedInUid = credential.user?.uid;
    });
  }

  Future<void> _createOrGetRoom() async {
    final postId = int.tryParse(_postIdController.text.trim());
    if (postId == null) {
      throw const SmokeException('post_id must be a number.');
    }

    final json = await _requestJson(
      'POST',
      'chat/rooms',
      body: {'post_id': postId},
    );
    final roomId = json['room_id']?.toString();
    if (roomId == null || roomId.isEmpty) {
      throw const SmokeException('Response did not include room_id.');
    }
    setState(() {
      _roomIdController.text = roomId;
    });
    await _startFirestoreListener(roomId);
  }

  Future<void> _listenToExistingRoom() async {
    final roomId = _requireRoomId();
    await _startFirestoreListener(roomId);
  }

  Future<void> _sendMessage() async {
    final roomId = _requireRoomId();
    final text = _messageController.text.trim();
    if (text.isEmpty) {
      throw const SmokeException('Message text is required.');
    }
    final clientMessageId =
        'flutter-smoke-${DateTime.now().microsecondsSinceEpoch}';

    final json = await _requestJson(
      'POST',
      'chat/rooms/${Uri.encodeComponent(roomId)}/messages',
      body: {
        'text': text,
        'client_message_id': clientMessageId,
      },
    );
    final messageId = json['message_id']?.toString() ?? '<unknown>';
    _addEvent('Spring API accepted message_id=$messageId.');
  }

  Future<void> _markRead() async {
    final roomId = _requireRoomId();
    final json = await _requestJson(
      'PATCH',
      'chat/rooms/${Uri.encodeComponent(roomId)}/read',
    );
    final responseRoomId = json['room_id'];
    final readValue = json['read'];
    final read = readValue == true ? 'true' : '$readValue';
    _addEvent('Spring API read result: room_id=$responseRoomId, read=$read.');
  }

  Future<void> _refreshRoomList() async {
    final json = await _requestJson(
      'GET',
      'chat/rooms',
      query: {'page': '0', 'size': '20'},
    );
    final rawItems = json['items'];
    final rooms = rawItems is List
        ? rawItems
            .whereType<Map<String, dynamic>>()
            .map(_RoomListItem.fromJson)
            .toList(growable: false)
        : <_RoomListItem>[];
    setState(() {
      _rooms
        ..clear()
        ..addAll(rooms);
    });
  }

  Future<void> _registerFcmToken() async {
    _requireFirebaseReady();
    await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    final token = await FirebaseMessaging.instance.getToken();
    if (token == null || token.isEmpty) {
      throw const SmokeException(
        'FCM token unavailable on this platform/configuration.',
      );
    }

    final json = await _requestJson(
      'PUT',
      'users/me/fcm-token',
      body: {
        'fcm_token': token,
        'platform': _platformName(),
      },
    );
    final registered = json['registered'];
    _addEvent(
      'Spring API registered FCM token ${_redactToken(token)}; '
      'registered=$registered.',
    );
  }

  Future<void> _startFirestoreListener(String roomId) async {
    _requireFirebaseReady();
    await _roomSubscription?.cancel();
    await _messageSubscription?.cancel();

    setState(() {
      _roomState = null;
      _messages.clear();
      _listenerState = 'Listening to chat_rooms/$roomId';
    });

    final roomRef =
        FirebaseFirestore.instance.collection('chat_rooms').doc(roomId);

    _roomSubscription = roomRef.snapshots().listen(
      (snapshot) {
        setState(() {
          _roomState = snapshot.data();
        });
      },
      onError: (Object error) {
        _addEvent('Room listener error: ${_safeError(error)}');
      },
    );

    _messageSubscription = roomRef
        .collection('messages')
        .orderBy('created_at')
        .snapshots()
        .listen(
      (snapshot) {
        final messages = snapshot.docs
            .map(
              (document) => _ChatMessageItem(
                documentId: document.id,
                data: document.data(),
              ),
            )
            .toList(growable: false);
        setState(() {
          _messages
            ..clear()
            ..addAll(messages);
        });
      },
      onError: (Object error) {
        _addEvent('Message listener error: ${_safeError(error)}');
      },
    );
  }

  Future<Map<String, dynamic>> _requestJson(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) async {
    final token = _bearerTokenController.text.trim();
    if (token.isEmpty) {
      throw const SmokeException('Spring Bearer token is required.');
    }

    final request = http.Request(method, _apiUri(path, query));
    request.headers['Authorization'] = 'Bearer $token';
    request.headers['Accept'] = 'application/json';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);
    final decoded = _decodeJson(response.body);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = decoded is Map<String, dynamic>
          ? decoded['message'] ?? decoded['error_code'] ?? response.body
          : response.body;
      throw SmokeException(
        'HTTP ${response.statusCode} from /api/$path: $message',
      );
    }

    if (decoded == null) {
      return <String, dynamic>{};
    }
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    throw SmokeException('Expected JSON object from /api/$path.');
  }

  Object? _decodeJson(String body) {
    if (body.trim().isEmpty) {
      return null;
    }
    final decoded = jsonDecode(body);
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
    return decoded;
  }

  Uri _apiUri(String path, Map<String, String>? query) {
    final base = _apiBaseUrlController.text.trim();
    if (base.isEmpty) {
      throw const SmokeException('API base URL is required.');
    }
    final normalizedBase = base.replaceFirst(RegExp(r'/+$'), '');
    return Uri.parse('$normalizedBase/api/$path')
        .replace(queryParameters: query);
  }

  void _requireFirebaseReady() {
    if (!_firebaseReady) {
      throw SmokeException(
        'Firebase is not initialized. Configure the client app locally. '
        '${_firebaseInitError ?? ''}',
      );
    }
  }

  String _requireRoomId() {
    final roomId = _roomIdController.text.trim();
    if (roomId.isEmpty) {
      throw const SmokeException('room_id is required.');
    }
    return roomId;
  }

  void _addEvent(String event) {
    if (!mounted) {
      return;
    }
    setState(() {
      _events.insert(0, '${DateTime.now().toIso8601String()}  $event');
      if (_events.length > 60) {
        _events.removeLast();
      }
    });
  }

  String _safeError(Object error) {
    final token = _bearerTokenController.text.trim();
    final message = error.toString();
    return token.isEmpty ? message : message.replaceAll(token, '');
  }

  String _platformName() {
    if (kIsWeb) {
      return 'WEB';
    }
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'ANDROID',
      TargetPlatform.iOS => 'IOS',
      _ => 'WEB',
    };
  }

  String _redactToken(String token) {
    if (token.length <= 12) {
      return '<redacted:${token.length} chars>';
    }
    return '${token.substring(0, 4)}...${token.substring(token.length - 4)}'
        ' (${token.length} chars)';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('PetNose Firebase Chat Visual Smoke'),
        backgroundColor: colorScheme.surfaceContainerHighest,
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 920;
            final controls = _ControlsPanel(
              apiBaseUrlController: _apiBaseUrlController,
              bearerTokenController: _bearerTokenController,
              postIdController: _postIdController,
              roomIdController: _roomIdController,
              messageController: _messageController,
              busy: _busy,
              currentAction: _currentAction,
              firebaseReady: _firebaseReady,
              firebaseInitError: _firebaseInitError,
              firebaseUid: _firebaseUid,
              signedInUid: _signedInUid,
              listenerState: _listenerState,
              onGetFirebaseToken: () => _runAction(
                'Get Firebase Custom Token',
                _getFirebaseCustomToken,
              ),
              onCreateRoom: () => _runAction(
                'Create / Get Chat Room',
                _createOrGetRoom,
              ),
              onListenToRoom: () => _runAction(
                'Start Firestore Listener',
                _listenToExistingRoom,
              ),
              onSendMessage: () => _runAction('Send Message', _sendMessage),
              onMarkRead: () => _runAction('Mark Read', _markRead),
              onRefreshRooms: () => _runAction(
                'Refresh Room List',
                _refreshRoomList,
              ),
              onRegisterFcm: () => _runAction(
                'Register FCM Token',
                _registerFcmToken,
              ),
            );
            final results = _ResultsPanel(
              roomState: _roomState,
              rooms: _rooms,
              messages: _messages,
              events: _events,
            );

            if (narrow) {
              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  controls,
                  const SizedBox(height: 16),
                  results,
                ],
              );
            }

            return Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 420,
                    child: SingleChildScrollView(child: controls),
                  ),
                  const SizedBox(width: 16),
                  Expanded(child: SingleChildScrollView(child: results)),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ControlsPanel extends StatelessWidget {
  const _ControlsPanel({
    required this.apiBaseUrlController,
    required this.bearerTokenController,
    required this.postIdController,
    required this.roomIdController,
    required this.messageController,
    required this.busy,
    required this.currentAction,
    required this.firebaseReady,
    required this.firebaseInitError,
    required this.firebaseUid,
    required this.signedInUid,
    required this.listenerState,
    required this.onGetFirebaseToken,
    required this.onCreateRoom,
    required this.onListenToRoom,
    required this.onSendMessage,
    required this.onMarkRead,
    required this.onRefreshRooms,
    required this.onRegisterFcm,
  });

  final TextEditingController apiBaseUrlController;
  final TextEditingController bearerTokenController;
  final TextEditingController postIdController;
  final TextEditingController roomIdController;
  final TextEditingController messageController;
  final bool busy;
  final String? currentAction;
  final bool firebaseReady;
  final String? firebaseInitError;
  final String? firebaseUid;
  final String? signedInUid;
  final String listenerState;
  final VoidCallback onGetFirebaseToken;
  final VoidCallback onCreateRoom;
  final VoidCallback onListenToRoom;
  final VoidCallback onSendMessage;
  final VoidCallback onMarkRead;
  final VoidCallback onRefreshRooms;
  final VoidCallback onRegisterFcm;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Session', style: textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              controller: apiBaseUrlController,
              decoration: const InputDecoration(
                labelText: 'API base URL',
                helperText:
                    'Android emulator: http://10.0.2.2:8080; device: PC LAN IP',
                prefixIcon: Icon(Icons.link),
              ),
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: bearerTokenController,
              decoration: const InputDecoration(
                labelText: 'Spring Bearer token',
                prefixIcon: Icon(Icons.key),
              ),
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: postIdController,
              decoration: const InputDecoration(
                labelText: 'post_id',
                prefixIcon: Icon(Icons.article_outlined),
              ),
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: roomIdController,
              decoration: const InputDecoration(
                labelText: 'room_id',
                prefixIcon: Icon(Icons.forum_outlined),
              ),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: messageController,
              decoration: const InputDecoration(
                labelText: 'Message text',
                prefixIcon: Icon(Icons.chat_bubble_outline),
              ),
              minLines: 2,
              maxLines: 4,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _ActionButton(
                  icon: Icons.login,
                  label: 'Get Firebase Custom Token',
                  busy: busy,
                  onPressed: onGetFirebaseToken,
                ),
                _ActionButton(
                  icon: Icons.add_comment_outlined,
                  label: 'Create / Get Chat Room',
                  busy: busy,
                  onPressed: onCreateRoom,
                ),
                _ActionButton(
                  icon: Icons.sensors,
                  label: 'Start Listener',
                  busy: busy,
                  onPressed: onListenToRoom,
                ),
                _ActionButton(
                  icon: Icons.send,
                  label: 'Send Message',
                  busy: busy,
                  onPressed: onSendMessage,
                ),
                _ActionButton(
                  icon: Icons.done_all,
                  label: 'Mark Read',
                  busy: busy,
                  onPressed: onMarkRead,
                ),
                _ActionButton(
                  icon: Icons.refresh,
                  label: 'Refresh Room List',
                  busy: busy,
                  onPressed: onRefreshRooms,
                ),
                _ActionButton(
                  icon: Icons.notifications_active_outlined,
                  label: 'Register FCM Token',
                  busy: busy,
                  onPressed: onRegisterFcm,
                ),
              ],
            ),
            if (busy) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                minHeight: 3,
                semanticsLabel: currentAction,
              ),
            ],
            const SizedBox(height: 16),
            _StatusLine(
              icon: firebaseReady ? Icons.check_circle : Icons.error_outline,
              label: 'Firebase client',
              value: firebaseReady ? 'initialized' : 'not initialized',
            ),
            if (firebaseInitError != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  firebaseInitError!,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall,
                ),
              ),
            _StatusLine(
              icon: Icons.verified_user_outlined,
              label: 'firebase_uid',
              value: firebaseUid ?? '-',
            ),
            _StatusLine(
              icon: Icons.person_outline,
              label: 'signed-in uid',
              value: signedInUid ?? '-',
            ),
            _StatusLine(
              icon: Icons.stream,
              label: 'listener',
              value: listenerState,
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultsPanel extends StatelessWidget {
  const _ResultsPanel({
    required this.roomState,
    required this.rooms,
    required this.messages,
    required this.events,
  });

  final Map<String, dynamic>? roomState;
  final List<_RoomListItem> rooms;
  final List<_ChatMessageItem> messages;
  final List<String> events;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _RoomStateCard(roomState: roomState),
        const SizedBox(height: 16),
        _MessagesCard(messages: messages),
        const SizedBox(height: 16),
        _RoomListCard(rooms: rooms),
        const SizedBox(height: 16),
        _EventLogCard(events: events),
      ],
    );
  }
}

class _RoomStateCard extends StatelessWidget {
  const _RoomStateCard({required this.roomState});

  final Map<String, dynamic>? roomState;

  @override
  Widget build(BuildContext context) {
    final rows = <MapEntry<String, Object?>>[
      MapEntry('room_id', roomState?['room_id']),
      MapEntry('room_status', roomState?['room_status']),
      MapEntry('message_enabled', roomState?['message_enabled']),
      MapEntry('post_status_snapshot', roomState?['post_status_snapshot']),
      MapEntry('updated_at', roomState?['updated_at']),
    ];
    return _PanelCard(
      title: 'Firestore Room',
      icon: Icons.meeting_room_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows
            .map((row) => _KeyValue(label: row.key, value: row.value))
            .toList(growable: false),
      ),
    );
  }
}

class _MessagesCard extends StatelessWidget {
  const _MessagesCard({required this.messages});

  final List<_ChatMessageItem> messages;

  @override
  Widget build(BuildContext context) {
    return _PanelCard(
      title: 'Realtime Messages',
      icon: Icons.chat_outlined,
      child: messages.isEmpty
          ? const Text('No messages observed.')
          : Column(
              children: messages
                  .map(
                    (message) => ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        message.text,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 2,
                      ),
                      subtitle: Text(
                        [
                          'message_id=${message.messageId}',
                          'sender_uid=${message.senderUid}',
                          'type=${message.type}',
                          'created_at=${_formatValue(message.createdAt)}',
                        ].join('\n'),
                      ),
                      isThreeLine: true,
                    ),
                  )
                  .toList(growable: false),
            ),
    );
  }
}

class _RoomListCard extends StatelessWidget {
  const _RoomListCard({required this.rooms});

  final List<_RoomListItem> rooms;

  @override
  Widget build(BuildContext context) {
    return _PanelCard(
      title: 'Spring Room List',
      icon: Icons.list_alt,
      child: rooms.isEmpty
          ? const Text('No rooms loaded.')
          : Column(
              children: rooms
                  .map(
                    (room) => ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(room.roomId),
                      subtitle: Text(
                        [
                          'post_id=${room.postId}',
                          'post_status=${room.postStatus}',
                          'preview=${room.preview}',
                          'unread_count=${room.unreadCount}',
                        ].join('\n'),
                      ),
                      isThreeLine: true,
                    ),
                  )
                  .toList(growable: false),
            ),
    );
  }
}

class _EventLogCard extends StatelessWidget {
  const _EventLogCard({required this.events});

  final List<String> events;

  @override
  Widget build(BuildContext context) {
    return _PanelCard(
      title: 'Event Log',
      icon: Icons.receipt_long,
      child: events.isEmpty
          ? const Text('No events yet.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: events
                  .map(
                    (event) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: SelectableText(event),
                    ),
                  )
                  .toList(growable: false),
            ),
    );
  }
}

class _PanelCard extends StatelessWidget {
  const _PanelCard({
    required this.title,
    required this.icon,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon),
                const SizedBox(width: 8),
                Expanded(child: Text(title, style: textTheme.titleMedium)),
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.busy,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      icon: Icon(icon, size: 18),
      label: Text(label),
      onPressed: busy ? null : onPressed,
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          SizedBox(width: 116, child: Text(label)),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}

class _KeyValue extends StatelessWidget {
  const _KeyValue({required this.label, required this.value});

  final String label;
  final Object? value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 168, child: Text(label)),
          Expanded(child: SelectableText(_formatValue(value))),
        ],
      ),
    );
  }
}

class _RoomListItem {
  const _RoomListItem({
    required this.roomId,
    required this.postId,
    required this.postStatus,
    required this.preview,
    required this.unreadCount,
  });

  factory _RoomListItem.fromJson(Map<String, dynamic> json) {
    return _RoomListItem(
      roomId: json['room_id']?.toString() ?? '<missing>',
      postId: json['post_id']?.toString() ?? '-',
      postStatus: json['post_status']?.toString() ?? '-',
      preview: json['last_message_preview']?.toString() ?? '-',
      unreadCount: json['unread_count']?.toString() ?? '-',
    );
  }

  final String roomId;
  final String postId;
  final String postStatus;
  final String preview;
  final String unreadCount;
}

class _ChatMessageItem {
  const _ChatMessageItem({
    required this.documentId,
    required this.data,
  });

  final String documentId;
  final Map<String, dynamic> data;

  String get messageId => data['message_id']?.toString() ?? documentId;

  String get senderUid => data['sender_uid']?.toString() ?? '-';

  String get type => data['type']?.toString() ?? '-';

  String get text => data['text']?.toString() ?? '';

  Object? get createdAt => data['created_at'];
}

class SmokeException implements Exception {
  const SmokeException(this.message);

  final String message;

  @override
  String toString() => message;
}

String _formatValue(Object? value) {
  if (value == null) {
    return '-';
  }
  if (value is Timestamp) {
    return value.toDate().toIso8601String();
  }
  if (value is DateTime) {
    return value.toIso8601String();
  }
  if (value is Map) {
    return value.entries
        .map((entry) => '${entry.key}: ${_formatValue(entry.value)}')
        .join(', ');
  }
  if (value is Iterable) {
    return value.map(_formatValue).join(', ');
  }
  return value.toString();
}
