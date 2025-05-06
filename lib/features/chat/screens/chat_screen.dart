import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import '../../auth/auth_service.dart';
import '../../../config/supabase.dart';
import '../../../models/message_model.dart';
import 'package:audio_waveforms/audio_waveforms.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';

class ChatScreen extends StatefulWidget {
  final String friendName;
  final String friendId;
  final String conversationId;

  const ChatScreen({
    super.key,
    required this.friendName,
    required this.friendId,
    required this.conversationId,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final AuthService _authService = AuthService();
  final ScrollController _scrollController = ScrollController();
  final ImagePicker _picker = ImagePicker();
  late final RecorderController _recorderController;
  List<MessageModel> _messages = [];
  RealtimeChannel? _messagesChannel;
  bool _canSend = false;
  String? _currentUserId;
  bool _isLoading = true;
  bool _isUploading = false;
  bool _isLoadingMore = false;
  String? _errorMessage;
  final int _messagesPerPage = 20;
  bool _hasMoreMessages = true;
  String? _friendProfilePicture;
  Map<String, String> _imageUrls = {};
  Map<String, String> _audioUrls = {};
  Map<String, String> _localAudioPaths = {};
  bool _isRecording = false;
  String? _recordedFilePath;

  @override
  void initState() {
    super.initState();
    _messageController.addListener(_updateCanSend);
    _scrollController.addListener(_scrollListener);
    _recorderController = RecorderController()
      ..androidEncoder = AndroidEncoder.aac
      ..androidOutputFormat = AndroidOutputFormat.mpeg4
      ..iosEncoder = IosEncoder.kAudioFormatMPEG4AAC
      ..sampleRate = 44100;
    _initialize();
  }

  void _updateCanSend() {
    final newCanSend = _messageController.text.trim().isNotEmpty;
    if (_canSend != newCanSend) {
      setState(() {
        _canSend = newCanSend;
      });
    }
  }

  Future<void> _initialize() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await _requestPermissions();
      await _fetchCurrentUser();
      await _fetchFriendProfilePicture();
      await _fetchMessages();
      _setupRealtimeListener();
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to initialize chat: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _requestPermissions() async {
    final status = await Permission.microphone.request();
    if (status != PermissionStatus.granted) {
      throw Exception('Microphone permission not granted');
    }
  }

  Future<void> _fetchCurrentUser() async {
    try {
      final currentUser = await _authService.getCurrentUser();
      if (currentUser == null) {
        throw Exception('User not authenticated');
      }
      setState(() {
        _currentUserId = currentUser.id;
      });
    } catch (e) {
      throw Exception('Failed to load user: $e');
    }
  }

  Future<void> _fetchFriendProfilePicture() async {
    try {
      final friendProfile = await SupabaseConfig.client
          .from('profiles')
          .select('profile_picture')
          .eq('id', widget.friendId)
          .single();

      if (friendProfile['profile_picture'] != null) {
        final signedUrl = await SupabaseConfig.client.storage
            .from('avatars')
            .createSignedUrl('${widget.friendId}.jpg', 60);
        setState(() {
          _friendProfilePicture = signedUrl;
        });
      }
    } catch (e) {
      print('Failed to fetch friend profile picture: $e');
    }
  }

  Future<void> _fetchMessages({bool loadMore = false}) async {
    if (widget.conversationId.isEmpty || (!_hasMoreMessages && loadMore)) return;

    if (loadMore) {
      setState(() {
        _isLoadingMore = true;
      });
    }

    try {
      final response = await SupabaseConfig.client
          .from('messages')
          .select('*')
          .eq('conversation_id', widget.conversationId)
          .order('created_at', ascending: false)
          .range(
            loadMore ? _messages.length : 0,
            loadMore ? _messages.length + _messagesPerPage - 1 : _messagesPerPage - 1,
          );

      final newMessages = (response as List)
          .map((json) => MessageModel.fromJson(json))
          .toList()
          .reversed
          .toList();

      setState(() {
        if (loadMore) {
          _messages.insertAll(0, newMessages);
          _hasMoreMessages = newMessages.length == _messagesPerPage;
        } else {
          _messages = newMessages;
          _hasMoreMessages = newMessages.length == _messagesPerPage;
        }
      });

      if (!loadMore) {
        _scrollToBottom();
      }
    } catch (e) {
      throw Exception('Failed to load messages: $e');
    } finally {
      if (loadMore) {
        setState(() {
          _isLoadingMore = false;
        });
      }
    }
  }

  void _scrollListener() {
    if (_scrollController.position.pixels <= _scrollController.position.minScrollExtent + 50 &&
        !_isLoadingMore &&
        _hasMoreMessages) {
      _fetchMessages(loadMore: true);
    }
  }

  void _setupRealtimeListener() {
    _messagesChannel?.unsubscribe();
    _messagesChannel = SupabaseConfig.client.channel('messages_${widget.conversationId}')
      ..onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'conversation_id',
            value: widget.conversationId,
          ),
          callback: (payload) {
            final newMessage = MessageModel.fromJson(payload.newRecord);
            setState(() {
              _messages.add(newMessage);
            });
            _scrollToBottom();
          })
      ..subscribe();
  }

  void _scrollToBottom() {
    Future.delayed(Duration.zero, () {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  Future<void> _sendMessage() async {
    if (!_canSend || widget.conversationId.isEmpty) return;
    final currentUser = await _authService.getCurrentUser();
    if (currentUser == null) return;

    final message = MessageModel(
      id: '',
      content: _messageController.text.trim(),
      senderId: currentUser.id,
      createdAt: DateTime.now(),
      conversationId: widget.conversationId,
      mediaType: 'text',
      mediaUrl: null,
    );

    try {
      await SupabaseConfig.client.from('messages').insert(message.toJson());
      _messageController.clear();
      setState(() {
        _canSend = false;
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send message: $e')),
      );
    }
  }

  Future<void> _startRecording() async {
    if (_isRecording) return;
    final directory = await getApplicationDocumentsDirectory();
    final path = '${directory.path}/${DateTime.now().millisecondsSinceEpoch}.m4a';

    try {
      await _recorderController.record(path: path);
      setState(() {
        _isRecording = true;
        _recordedFilePath = path;
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to start recording: $e')),
      );
    }
  }

  Future<void> _stopRecordingAndSend() async {
    if (!_isRecording) return;

    try {
      final path = await _recorderController.stop();
      setState(() {
        _isRecording = false;
      });

      if (path == null || _recordedFilePath == null) {
        throw Exception('Recording path is null');
      }

      final currentUser = await _authService.getCurrentUser();
      if (currentUser == null) {
        throw Exception('User not authenticated');
      }

      final file = File(_recordedFilePath!);
      final fileName = '${DateTime.now().millisecondsSinceEpoch}_${currentUser.id}.m4a';
      await SupabaseConfig.client.storage
          .from('chat-media')
          .upload(fileName, file, fileOptions: const FileOptions(contentType: 'audio/m4a'));

      final message = MessageModel(
        id: '',
        content: '',
        senderId: currentUser.id,
        createdAt: DateTime.now(),
        conversationId: widget.conversationId,
        mediaType: 'audio',
        mediaUrl: fileName,
      );

      await SupabaseConfig.client.from('messages').insert(message.toJson());
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send audio: $e')),
      );
    } finally {
      setState(() {
        _isRecording = false;
        _recordedFilePath = null;
      });
    }
  }

  Future<void> _sendImageMessage() async {
    if (widget.conversationId.isEmpty) return;
    final currentUser = await _authService.getCurrentUser();
    if (currentUser == null) {
      print('DEBUG: User not authenticated - _authService.getCurrentUser() returned null');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('User not authenticated')),
      );
      return;
    }

    setState(() {
      _isUploading = true;
      _errorMessage = null;
    });

    try {
      final conversation = await SupabaseConfig.client
          .from('conversations')
          .select('id')
          .eq('id', widget.conversationId)
          .single();
      if (conversation == null) throw Exception('Conversation not found');

      final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
      if (image == null) return;

      final file = File(image.path);
      final fileName = '${DateTime.now().millisecondsSinceEpoch}_${currentUser.id}.jpg';
      await SupabaseConfig.client.storage
          .from('chat-media')
          .upload(fileName, file, fileOptions: const FileOptions(contentType: 'image/jpeg'));

      final message = MessageModel(
        id: '',
        content: '',
        senderId: currentUser.id,
        createdAt: DateTime.now(),
        conversationId: widget.conversationId,
        mediaType: 'image',
        mediaUrl: fileName,
      );

      await SupabaseConfig.client.from('messages').insert(message.toJson());
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to send image: $e';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send image: $e')),
      );
    } finally {
      setState(() {
        _isUploading = false;
      });
    }
  }

  Future<String> _getImageUrl(String mediaUrl) async {
    if (_imageUrls.containsKey(mediaUrl)) return _imageUrls[mediaUrl]!;
    final signedUrl = await SupabaseConfig.client.storage
        .from('chat-media')
        .createSignedUrl(mediaUrl, 60);
    _imageUrls[mediaUrl] = signedUrl;
    return signedUrl;
  }

  Future<String> _getAudioUrl(String mediaUrl) async {
    if (_audioUrls.containsKey(mediaUrl)) return _audioUrls[mediaUrl]!;
    final signedUrl = await SupabaseConfig.client.storage
        .from('chat-media')
        .createSignedUrl(mediaUrl, 60);
    _audioUrls[mediaUrl] = signedUrl;
    return signedUrl;
  }

  Future<String> _downloadAudio(String mediaUrl) async {
    if (_localAudioPaths.containsKey(mediaUrl)) return _localAudioPaths[mediaUrl]!;

    final signedUrl = await _getAudioUrl(mediaUrl);
    final directory = await getTemporaryDirectory();
    final localPath = '${directory.path}/${mediaUrl.split('/').last}';
    final file = File(localPath);

    final response = await SupabaseConfig.client.storage
        .from('chat-media')
        .download(mediaUrl);
    await file.writeAsBytes(response);

    _localAudioPaths[mediaUrl] = localPath;
    return localPath;
  }

  void _showMediaOptions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.mic, color: Color(0xFF4CAF50)),
                title: const Text(
                  'Send Audio',
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _startRecording();
                },
              ),
              ListTile(
                leading: const Icon(Icons.videocam, color: Color(0xFF4CAF50)),
                title: const Text(
                  'Send Video',
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Video sending not yet implemented')),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo, color: Color(0xFF4CAF50)),
                title: const Text(
                  'Send from Gallery',
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _sendImageMessage();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _onRefresh() async {
    await _fetchMessages(loadMore: false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () {
            context.go('/main/chats');
          },
        ),
        title: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundImage: _friendProfilePicture != null
                  ? NetworkImage(_friendProfilePicture!)
                  : null,
              child: _friendProfilePicture == null
                  ? Text(
                      widget.friendName.isNotEmpty
                          ? widget.friendName.substring(0, 1).toUpperCase()
                          : 'U',
                      style: const TextStyle(color: Colors.white),
                    )
                  : null,
            ),
            const SizedBox(width: 8),
            Text(
              widget.friendName,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        centerTitle: false,
        backgroundColor: const Color(0xFF4CAF50),
        elevation: 0,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: RefreshIndicator(
                onRefresh: _onRefresh,
                color: const Color(0xFF4CAF50),
                child: _buildMessagesList(),
              ),
            ),
            Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
              ),
              child: _buildMessageInput(),
            ),
          ],
        ),
      ),
      backgroundColor: Colors.grey[900],
    );
  }

  Widget _buildMessagesList() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF4CAF50)),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Container(
            height: MediaQuery.of(context).size.height - kToolbarHeight - 200,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  _errorMessage!,
                  style: TextStyle(color: Colors.red[400], fontSize: 16),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _initialize,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4CAF50),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'Retry',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_messages.isEmpty && !_isUploading) {
      return Center(
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Container(
            height: MediaQuery.of(context).size.height - kToolbarHeight - 200,
            child: Center(
              child: Text(
                'No messages yet. Start chatting with ${widget.friendName}!',
                style: TextStyle(color: Colors.grey[400], fontSize: 16),
              ),
            ),
          ),
        ),
      );
    }

    if (_isUploading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF4CAF50)),
      );
    }

    Map<String, List<MessageModel>> messagesByDate = {};
    for (var message in _messages) {
      final date = message.createdAt;
      final dateKey = '${date.day}/${date.month}/${date.year}';
      messagesByDate[dateKey] ??= [];
      messagesByDate[dateKey]!.add(message);
    }

    List<Widget> messageWidgets = [];
    if (_isLoadingMore) {
      messageWidgets.add(
        const Padding(
          padding: EdgeInsets.all(8.0),
          child: Center(
            child: CircularProgressIndicator(color: Color(0xFF4CAF50)),
          ),
        ),
      );
    }

    messagesByDate.forEach((date, messages) {
      messageWidgets.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          child: Center(
            child: Text(
              date,
              style: TextStyle(color: Colors.grey[400], fontSize: 12),
            ),
          ),
        ),
      );

      for (var message in messages) {
        final isSentByMe = _currentUserId != null && message.senderId == _currentUserId;
        messageWidgets.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 8.0),
            child: Align(
              alignment: isSentByMe ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: isSentByMe ? const Color(0xFF4CAF50) : Colors.grey[700],
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (message.mediaType == 'image' && message.mediaUrl != null)
                      FutureBuilder<String>(
                        future: _getImageUrl(message.mediaUrl!),
                        builder: (context, snapshot) {
                          if (snapshot.connectionState == ConnectionState.waiting) {
                            return const CircularProgressIndicator(color: Color(0xFF4CAF50));
                          }
                          if (snapshot.hasError || !snapshot.hasData) {
                            return const Text(
                              'Failed to load image',
                              style: TextStyle(color: Colors.red),
                            );
                          }
                          return Image.network(
                            snapshot.data!,
                            width: 200,
                            height: 200,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) => const Text(
                              'Failed to load image',
                              style: TextStyle(color: Colors.red),
                            ),
                          );
                        },
                      )
                    else if (message.mediaType == 'audio' && message.mediaUrl != null)
                      FutureBuilder<String>(
                        future: _downloadAudio(message.mediaUrl!),
                        builder: (context, snapshot) {
                          if (snapshot.connectionState == ConnectionState.waiting) {
                            return const CircularProgressIndicator(color: Color(0xFF4CAF50));
                          }
                          if (snapshot.hasError || !snapshot.hasData) {
                            return const Text(
                              'Failed to load audio',
                              style: TextStyle(color: Colors.red),
                            );
                          }
                          final playerController = PlayerController();
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: Icon(
                                  playerController.playerState == PlayerState.playing
                                      ? Icons.pause
                                      : Icons.play_arrow,
                                  color: Colors.white,
                                ),
                                onPressed: () async {
                                  try {
                                    if (playerController.playerState == PlayerState.playing) {
                                      await playerController.pausePlayer();
                                    } else {
                                      await playerController.preparePlayer(
                                        path: snapshot.data!,
                                        shouldExtractWaveform: true,
                                      );
                                      await playerController.startPlayer();
                                      // Add listener to handle completion if needed
                                      playerController.onCompletion.listen((event) {
                                        playerController.pausePlayer();
                                      });
                                    }
                                  } catch (e) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('Failed to play audio: $e')),
                                    );
                                  }
                                },
                              ),
                              Container(
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.3),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: SizedBox(
                                  width: 150, // Fixed width for waveform
                                  height: 40,
                                  child: AudioFileWaveforms(
                                    size: const Size(150, 40),
                                    playerController: playerController,
                                    playerWaveStyle: const PlayerWaveStyle(
                                      fixedWaveColor: Colors.white54,
                                      liveWaveColor: Colors.white,
                                      scaleFactor: 150, // Increase scale for more pronounced peaks
                                      waveThickness: 2.5, // Thicker waveform lines
                                      spacing: 3, // Adjust spacing for better readability
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      )
                    else
                      Text(
                        message.content,
                        style: const TextStyle(color: Colors.white),
                      ),
                    const SizedBox(height: 4),
                    Text(
                      '${message.createdAt.hour}:${message.createdAt.minute.toString().padLeft(2, '0')}',
                      style: TextStyle(color: Colors.grey[400], fontSize: 10),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }
    });

    return ListView(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 80.0),
      children: messageWidgets,
    );
  }

  Widget _buildMessageInput() {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.attach_file, color: Color(0xFF4CAF50)),
            onPressed: () => _showMediaOptions(context),
            tooltip: 'Attach Media',
          ),
          Expanded(
            child: _isRecording
                ? AudioWaveforms(
                    size: Size(MediaQuery.of(context).size.width * 0.7, 50),
                    recorderController: _recorderController,
                    waveStyle: const WaveStyle(
                      waveColor: Colors.white,
                      extendWaveform: true,
                      showMiddleLine: false,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12.0),
                      color: Colors.grey[800],
                    ),
                    padding: const EdgeInsets.only(left: 16),
                  )
                : TextField(
                    controller: _messageController,
                    decoration: InputDecoration(
                      hintText: 'Type a message...',
                      hintStyle: TextStyle(color: Colors.grey[400]),
                      filled: true,
                      fillColor: Colors.grey[800],
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20.0),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16.0,
                        vertical: 10.0,
                      ),
                    ),
                    style: const TextStyle(color: Colors.white),
                    minLines: 1,
                    maxLines: 5,
                  ),
          ),
          const SizedBox(width: 8.0),
          _isRecording
              ? IconButton(
                  icon: const Icon(Icons.stop, color: Color(0xFF4CAF50)),
                  onPressed: _stopRecordingAndSend,
                  tooltip: 'Stop Recording',
                )
              : IconButton(
                  icon: Icon(
                    Icons.send,
                    color: _canSend ? const Color(0xFF4CAF50) : Colors.grey,
                  ),
                  onPressed: _canSend ? _sendMessage : null,
                  tooltip: 'Send',
                ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.removeListener(_scrollListener);
    _scrollController.dispose();
    _messagesChannel?.unsubscribe();
    _recorderController.dispose();
    for (var path in _localAudioPaths.values) {
      File(path).deleteSync();
    }
    super.dispose();
  }
}