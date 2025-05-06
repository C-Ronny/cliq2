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
import 'package:camera/camera.dart';
import 'package:video_player/video_player.dart';
import 'dart:async';

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

class _ChatScreenState extends State<ChatScreen> with SingleTickerProviderStateMixin {
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
  String? _currentUserProfilePicture;
  Map<String, String> _imageUrls = {};
  Map<String, String> _audioUrls = {};
  Map<String, String> _videoUrls = {};
  Map<String, String> _localAudioPaths = {};
  Map<String, VideoPlayerController> _videoControllers = {};
  bool _isRecording = false;
  String? _recordedFilePath;
  CameraController? _cameraController;
  bool _isRecordingVideo = false;
  String? _recordedVideoPath;
  Timer? _recordingTimer;
  bool _isFrontCamera = true;
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  Map<String, DateTime> _dateSeparators = {};

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
    
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeIn),
    );
    
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
      _animationController.forward();
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
    final microphoneStatus = await Permission.microphone.request();
    if (microphoneStatus != PermissionStatus.granted) {
      throw Exception('Microphone permission not granted');
    }
    final cameraStatus = await Permission.camera.request();
    if (cameraStatus != PermissionStatus.granted) {
      throw Exception('Camera permission not granted');
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
      
      // Fetch current user's profile picture
      try {
        final userProfile = await SupabaseConfig.client
            .from('profiles')
            .select('profile_picture')
            .eq('id', currentUser.id)
            .single();

        if (userProfile['profile_picture'] != null) {
          final signedUrl = await SupabaseConfig.client.storage
              .from('avatars')
              .createSignedUrl('${currentUser.id}.jpg', 60);
          setState(() {
            _currentUserProfilePicture = signedUrl;
          });
        }
      } catch (e) {
        print('Failed to fetch current user profile picture: $e');
      }
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
        
        // Process date separators
        _processDateSeparators();
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
  
  void _processDateSeparators() {
    _dateSeparators.clear();
    if (_messages.isEmpty) return;
    
    DateTime? lastDate;
    for (var i = 0; i < _messages.length; i++) {
      final message = _messages[i];
      final messageDate = DateTime(
        message.createdAt.year,
        message.createdAt.month,
        message.createdAt.day,
      );
      
      if (lastDate == null || messageDate != lastDate) {
        _dateSeparators[message.id] = messageDate;
        lastDate = messageDate;
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
              _processDateSeparators();
            });
            _scrollToBottom();
          })
      ..subscribe();
  }

  void _scrollToBottom() {
    Future.delayed(Duration.zero, () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
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
        SnackBar(
          content: Text('Failed to send message: $e'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
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
        SnackBar(
          content: Text('Failed to start recording: $e'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
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

      // Show preview and confirmation dialog
      _showAudioPreview(File(_recordedFilePath!));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to record audio: $e'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('User not authenticated'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      return;
    }

    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 80,
      );
      if (image == null) return;

      // Show preview and confirmation dialog
      final file = File(image.path);
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: Colors.grey[900],
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text(
            'Send Image',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(
                  file,
                  height: 300,
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Send this image?',
                style: TextStyle(color: Colors.white70),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              style: TextButton.styleFrom(foregroundColor: Colors.grey),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(context);
                await _uploadAndSendImage(file);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4CAF50),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Send'),
            ),
          ],
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to select image: $e'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  // New method to handle the actual upload and sending
  Future<void> _uploadAndSendImage(File file) async {
    setState(() {
      _isUploading = true;
      _errorMessage = null;
    });

    try {
      final currentUser = await _authService.getCurrentUser();
      if (currentUser == null) throw Exception('User not authenticated');

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
        SnackBar(
          content: Text('Failed to send image: $e'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    } finally {
      setState(() {
        _isUploading = false;
      });
    }
  }

  Future<void> _startVideoRecording() async {
    if (_isRecordingVideo) return;

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw Exception('No camera available');
      _cameraController?.dispose();
      _cameraController = CameraController(
        _isFrontCamera ? cameras.firstWhere((camera) => camera.lensDirection == CameraLensDirection.front,
            orElse: () => cameras.first) : cameras.firstWhere((camera) => camera.lensDirection == CameraLensDirection.back,
            orElse: () => cameras.first),
        ResolutionPreset.medium,
      );
      await _cameraController!.initialize();

      final directory = await getTemporaryDirectory();
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      final path = '${directory.path}/${DateTime.now().millisecondsSinceEpoch}.mp4';

      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.grey[900],
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (context) => StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              height: MediaQuery.of(context).size.height * 0.8,
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  Container(
                    height: 5,
                    width: 40,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.grey[600],
                      borderRadius: BorderRadius.circular(2.5),
                    ),
                  ),
                  const Text(
                    'Record Video',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: CameraPreview(_cameraController!),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (!_isRecordingVideo)
                        GestureDetector(
                          onTap: () async {
                            try {
                              await _cameraController!.startVideoRecording();
                              setModalState(() {
                                _isRecordingVideo = true;
                                _recordedVideoPath = path;
                              });
                              _recordingTimer = Timer(const Duration(seconds: 60), () async {
                                if (_isRecordingVideo) {
                                  final xFile = await _cameraController!.stopVideoRecording();
                                  setModalState(() {
                                    _isRecordingVideo = false;
                                  });
                                  Navigator.pop(context);
                                  _recordedVideoPath = xFile.path;
                                  await _sendVideoMessage();
                                }
                              });
                            } catch (e) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Failed to start video recording: $e'),
                                  backgroundColor: Colors.redAccent,
                                ),
                              );
                              Navigator.pop(context);
                            }
                          },
                          child: Container(
                            width: 80,
                            height: 80,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.2),
                              shape: BoxShape.circle,
                              border: Border.all(color: const Color(0xFF4CAF50), width: 3),
                            ),
                            child: const Center(
                              child: Icon(
                                Icons.circle,
                                color: Color(0xFF4CAF50),
                                size: 60,
                              ),
                            ),
                          ),
                        ),
                      if (_isRecordingVideo)
                        GestureDetector(
                          onTap: () async {
                            try {
                              final xFile = await _cameraController!.stopVideoRecording();
                              _recordingTimer?.cancel();
                              setModalState(() {
                                _isRecordingVideo = false;
                              });
                              Navigator.pop(context);
                              _recordedVideoPath = xFile.path;
                              
                              // Show preview before sending
                              _showVideoPreview(File(xFile.path));
                            } catch (e) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Failed to stop video recording: $e'),
                                  backgroundColor: Colors.redAccent,
                                ),
                              );
                            }
                          },
                          child: Container(
                            width: 80,
                            height: 80,
                            decoration: BoxDecoration(
                              color: Colors.red.withOpacity(0.2),
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.red, width: 3),
                            ),
                            child: const Center(
                              child: Icon(
                                Icons.stop,
                                color: Colors.red,
                                size: 40,
                              ),
                            ),
                          ),
                        ),
                      const SizedBox(width: 24),
                      GestureDetector(
                        onTap: _isRecordingVideo ? null : () async {
                          try {
                            setState(() {
                              _isFrontCamera = !_isFrontCamera;
                            });
                            final cameras = await availableCameras();
                            _cameraController?.dispose();
                            _cameraController = CameraController(
                              _isFrontCamera ? cameras.firstWhere((camera) => camera.lensDirection == CameraLensDirection.front,
                                  orElse: () => cameras.first) : cameras.firstWhere((camera) => camera.lensDirection == CameraLensDirection.back,
                                  orElse: () => cameras.first),
                              ResolutionPreset.medium,
                            );
                            await _cameraController!.initialize();
                            setModalState(() {});
                          } catch (e) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Failed to switch camera: $e'),
                                backgroundColor: Colors.redAccent,
                              ),
                            );
                          }
                        },
                        child: Container(
                          width: 50,
                          height: 50,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.1),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.flip_camera_ios_rounded,
                            color: Colors.white,
                            size: 30,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            );
          },
        ),
      ).whenComplete(() {
        _recordingTimer?.cancel();
        _cameraController?.dispose();
        _cameraController = null;
        if (_isRecordingVideo) {
          setState(() {
            _isRecordingVideo = false;
          });
        }
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to initialize video recording: $e'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      _cameraController?.dispose();
      _cameraController = null;
    }
  }

  Future<void> _sendVideoMessage() async {
    if (_recordedVideoPath == null || widget.conversationId.isEmpty) return;
    final currentUser = await _authService.getCurrentUser();
    if (currentUser == null) return;

    setState(() {
      _isUploading = true;
      _errorMessage = null;
    });

    try {
      final file = File(_recordedVideoPath!);
      if (!await file.exists()) {
        throw Exception('Video file not found at: $_recordedVideoPath');
      }
      final fileName = '${DateTime.now().millisecondsSinceEpoch}_${currentUser.id}.mp4';
      await SupabaseConfig.client.storage
          .from('chat-media')
          .upload(fileName, file, fileOptions: const FileOptions(contentType: 'video/mp4'));

      final message = MessageModel(
        id: '',
        content: '',
        senderId: currentUser.id,
        createdAt: DateTime.now(),
        conversationId: widget.conversationId,
        mediaType: 'video',
        mediaUrl: fileName,
      );

      await SupabaseConfig.client.from('messages').insert(message.toJson());
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to send video: $e';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to send video: $e'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    } finally {
      setState(() {
        _isUploading = false;
        _recordedVideoPath = null;
        _isRecordingVideo = false;
      });
      _cameraController?.dispose();
      _cameraController = null;
    }
  }

  Future<String> _getVideoUrl(String mediaUrl) async {
    if (_videoUrls.containsKey(mediaUrl)) return _videoUrls[mediaUrl]!;
    final signedUrl = await SupabaseConfig.client.storage
        .from('chat-media')
        .createSignedUrl(mediaUrl, 60);
    _videoUrls[mediaUrl] = signedUrl;
    return signedUrl;
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
          padding: const EdgeInsets.symmetric(vertical: 24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Share Media',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildMediaOption(
                    icon: Icons.mic,
                    label: 'Audio',
                    color: Colors.orange,
                    onTap: () {
                      Navigator.pop(context);
                      _startRecording();
                    },
                  ),
                  _buildMediaOption(
                    icon: Icons.videocam,
                    label: 'Video',
                    color: Colors.red,
                    onTap: () {
                      Navigator.pop(context);
                      _startVideoRecording();
                    },
                  ),
                  _buildMediaOption(
                    icon: Icons.photo,
                    label: 'Gallery',
                    color: Colors.purple,
                    onTap: () {
                      Navigator.pop(context);
                      _sendImageMessage();
                    },
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMediaOption({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                color: color.withOpacity(0.2),
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                color: color,
                size: 30,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onRefresh() async {
    await _fetchMessages(loadMore: false);
  }

  void _showChatOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 20.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.person, color: Color(0xFF4CAF50)),
              title: const Text(
                'View Profile',
                style: TextStyle(color: Colors.white),
              ),
              onTap: () {
                Navigator.pop(context);
                // Navigate to friend profile
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text('Viewing profile coming soon'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.block, color: Colors.orange),
              title: const Text(
                'Block User',
                style: TextStyle(color: Colors.white),
              ),
              onTap: () {
                Navigator.pop(context);
                _showBlockUserConfirmation();
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.redAccent),
              title: const Text(
                'Clear Chat',
                style: TextStyle(color: Colors.white),
              ),
              onTap: () {
                Navigator.pop(context);
                _showClearChatConfirmation();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showBlockUserConfirmation() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Block User',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: Text(
          'Are you sure you want to block ${widget.friendName}? You won\'t receive messages from them anymore.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            style: TextButton.styleFrom(foregroundColor: Colors.grey),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              // Implement block user functionality
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('${widget.friendName} has been blocked'),
                  backgroundColor: Colors.orange,
                  behavior: SnackBarBehavior.floating,
                ),
              );
              context.go('/main/chats');
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Block'),
          ),
        ],
      ),
    );
  }

  void _showClearChatConfirmation() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Clear Chat',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'Are you sure you want to clear all messages? This action cannot be undone.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            style: TextButton.styleFrom(foregroundColor: Colors.grey),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              // Implement clear chat functionality
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Text('Chat cleared'),
                  backgroundColor: Colors.redAccent,
                  behavior: SnackBarBehavior.floating,
                ),
              );
              setState(() {
                _messages = [];
                _dateSeparators.clear();
              });
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        leadingWidth: 40,
        titleSpacing: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () {
            context.go('/main/chats');
          },
        ),
        title: Row(
          children: [
            Hero(
              tag: 'profile_${widget.friendId}',
              child: CircleAvatar(
                radius: 18,
                backgroundColor: Colors.grey[700],
                backgroundImage: _friendProfilePicture != null
                    ? NetworkImage(_friendProfilePicture!)
                    : null,
                child: _friendProfilePicture == null
                    ? Text(
                        widget.friendName.isNotEmpty
                            ? widget.friendName.substring(0, 1).toUpperCase()
                            : 'U',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      )
                    : null,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              widget.friendName,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onPressed: _showChatOptions,
          ),
        ],
      ),
      body: Container(
        color: Colors.black,
        child: SafeArea(
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
      ),
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
          child: SizedBox(
            height: MediaQuery.of(context).size.height - kToolbarHeight - 200,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.error_outline,
                  color: Colors.redAccent,
                  size: 48,
                ),
                const SizedBox(height: 16),
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
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  ),
                  child: const Text(
                    'Retry',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
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
          child: SizedBox(
            height: MediaQuery.of(context).size.height - kToolbarHeight - 200,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.chat_bubble_outline,
                  color: Colors.grey[600],
                  size: 64,
                ),
                const SizedBox(height: 16),
                Text(
                  'No messages yet',
                  style: TextStyle(color: Colors.grey[400], fontSize: 18),
                ),
                const SizedBox(height: 8),
                Text(
                  'Start chatting with ${widget.friendName}!',
                  style: TextStyle(color: Colors.grey[600], fontSize: 14),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_isUploading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(color: Color(0xFF4CAF50)),
            const SizedBox(height: 16),
            Text(
              'Uploading media...',
              style: TextStyle(color: Colors.grey[400]),
            ),
          ],
        ),
      );
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

    // Group messages by date
    for (var i = 0; i < _messages.length; i++) {
      final message = _messages[i];
      
      // Add date separator if needed
      if (_dateSeparators.containsKey(message.id)) {
        final date = _dateSeparators[message.id]!;
        messageWidgets.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16.0),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.grey[800],
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  _formatDateHeader(date),
                  style: TextStyle(color: Colors.grey[400], fontSize: 12),
                ),
              ),
            ),
          ),
        );
      }
      
      final isSentByMe = _currentUserId != null && message.senderId == _currentUserId;
      messageWidgets.add(_buildMessageBubble(message, isSentByMe));
    }

    return FadeTransition(
      opacity: _fadeAnimation,
      child: ListView(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 16.0),
        children: messageWidgets,
      ),
    );
  }

  Widget _buildMessageBubble(MessageModel message, bool isSentByMe) {
    final time = '${message.createdAt.hour.toString().padLeft(2, '0')}:${message.createdAt.minute.toString().padLeft(2, '0')}';
    
    Widget messageContent;
    if (message.mediaType == 'image' && message.mediaUrl != null) {
      messageContent = _buildImageMessage(message);
    } else if (message.mediaType == 'audio' && message.mediaUrl != null) {
      messageContent = _buildAudioMessage(message, time);
    } else if (message.mediaType == 'video' && message.mediaUrl != null) {
      messageContent = _buildVideoMessage(message);
    } else {
      messageContent = Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            message.content,
            style: TextStyle(
              color: isSentByMe ? Colors.white : Colors.white,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            time,
            style: TextStyle(
              color: isSentByMe ? Colors.white70 : Colors.grey[400],
              fontSize: 10,
            ),
          ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 8.0),
      child: Row(
        mainAxisAlignment: isSentByMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isSentByMe) ...[
            CircleAvatar(
              radius: 16,
              backgroundColor: Colors.grey[700],
              backgroundImage: _friendProfilePicture != null
                  ? NetworkImage(_friendProfilePicture!)
                  : null,
              child: _friendProfilePicture == null
                  ? Text(
                      widget.friendName.isNotEmpty
                          ? widget.friendName.substring(0, 1).toUpperCase()
                          : 'U',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.7,
              ),
              padding: message.mediaType == 'image' || message.mediaType == 'video'
                  ? EdgeInsets.zero
                  : const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isSentByMe 
                  ? const Color(0xFF4CAF50) 
                  : const Color(0xFF6B7280),
                borderRadius: BorderRadius.circular(16),
              ),
              child: messageContent,
            ),
          ),
          if (isSentByMe) ...[
            const SizedBox(width: 8),
            CircleAvatar(
              radius: 16,
              backgroundColor: Colors.grey[700],
              backgroundImage: _currentUserProfilePicture != null
                  ? NetworkImage(_currentUserProfilePicture!)
                  : null,
              child: _currentUserProfilePicture == null
                  ? const Text(
                      'You',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 8,
                      ),
                    )
                  : null,
            ),
          ],
        ],
      ),
    );
  }

  // Helper method to format date headers
  String _formatDateHeader(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = DateTime(now.year, now.month, now.day - 1);
    
    if (date == today) {
      return 'Today';
    } else if (date == yesterday) {
      return 'Yesterday';
    } else if (now.difference(date).inDays < 7) {
      final weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
      return weekdays[date.weekday - 1];
    } else {
      return '${date.day}/${date.month}/${date.year}';
    }
  }

  // Helper methods for different message types
  Widget _buildImageMessage(MessageModel message) {
    return FutureBuilder<String>(
      future: _getImageUrl(message.mediaUrl!),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Container(
            width: 200,
            height: 200,
            decoration: BoxDecoration(
              color: Colors.grey[700],
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Center(
              child: CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 2,
              ),
            ),
          );
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return Container(
            width: 200,
            height: 60,
            decoration: BoxDecoration(
              color: Colors.grey[700],
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Center(
              child: Text(
                'Failed to load image',
                style: TextStyle(color: Colors.white70),
              ),
            ),
          );
        }
        return GestureDetector(
          onTap: () {
            // Show full-screen image view
            showDialog(
              context: context,
              builder: (context) => Dialog(
                backgroundColor: Colors.transparent,
                insetPadding: EdgeInsets.zero,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    InteractiveViewer(
                      child: Image.network(
                        snapshot.data!,
                        fit: BoxFit.contain,
                      ),
                    ),
                    Positioned(
                      top: 40,
                      right: 20,
                      child: IconButton(
                        icon: const Icon(Icons.close, color: Colors.white, size: 30),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
          child: Hero(
            tag: 'image_${message.id}',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(
                alignment: Alignment.bottomRight,
                children: [
                  Image.network(
                    snapshot.data!,
                    width: double.infinity,
                    height: 200,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => Container(
                      width: 200,
                      height: 60,
                      decoration: BoxDecoration(
                        color: Colors.grey[700],
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Center(
                        child: Text(
                          'Failed to load image',
                          style: TextStyle(color: Colors.white70),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Text(
                      '${message.createdAt.hour.toString().padLeft(2, '0')}:${message.createdAt.minute.toString().padLeft(2, '0')}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        backgroundColor: Colors.black54,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildAudioMessage(MessageModel message, String time) {
    return FutureBuilder<String>(
      future: _downloadAudio(message.mediaUrl!),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Container(
            width: 200,
            height: 60,
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Center(
              child: CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 2,
              ),
            ),
          );
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return Container(
            width: 200,
            height: 60,
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Center(
              child: Text(
                'Failed to load audio',
                style: TextStyle(color: Colors.white70),
              ),
            ),
          );
        }
        
        final playerController = PlayerController();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                StatefulBuilder(
                  builder: (context, setState) {
                    return IconButton(
                      icon: Icon(
                        playerController.playerState == PlayerState.playing
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_filled,
                        color: Colors.white,
                        size: 36,
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
                            playerController.onCompletion.listen((event) {
                              setState(() {}); // Refresh UI when playback completes
                            });
                          }
                          setState(() {}); // Refresh UI when play/pause state changes
                        } catch (e) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Failed to play audio: $e'),
                              backgroundColor: Colors.redAccent,
                            ),
                          );
                        }
                      },
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    );
                  },
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 150,
                  height: 40,
                  child: AudioFileWaveforms(
                    size: const Size(150, 40),
                    playerController: playerController,
                    playerWaveStyle: const PlayerWaveStyle(
                      fixedWaveColor: Colors.white54,
                      liveWaveColor: Colors.white,
                      scaleFactor: 150,
                      waveThickness: 2.5,
                      spacing: 3,
                    ),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 8.0),
              child: Text(
                time,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 10,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildVideoMessage(MessageModel message) {
    return FutureBuilder<String>(
      future: _getVideoUrl(message.mediaUrl!),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Container(
            width: 200,
            height: 150,
            decoration: BoxDecoration(
              color: Colors.grey[700],
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Center(
              child: CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 2,
              ),
            ),
          );
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return Container(
            width: 200,
            height: 60,
            decoration: BoxDecoration(
              color: Colors.grey[700],
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Center(
              child: Text(
                'Failed to load video',
                style: TextStyle(color: Colors.white70),
              ),
            ),
          );
        }
        
        if (!_videoControllers.containsKey(message.id)) {
          final controller = VideoPlayerController.network(snapshot.data!);
          _videoControllers[message.id] = controller;
          controller.initialize().then((_) {
            setState(() {});
          }).catchError((e) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Failed to initialize video: $e'),
                backgroundColor: Colors.redAccent,
              ),
            );
          });
        }
        
        final controller = _videoControllers[message.id]!;
        return GestureDetector(
          onTap: () {
            if (controller.value.isInitialized) {
              if (controller.value.isPlaying) {
                controller.pause();
              } else {
                controller.play();
              }
              setState(() {});
            }
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(
              alignment: Alignment.center,
              children: [
                controller.value.isInitialized
                    ? SizedBox(
                        width: 200,
                        height: 200,
                        child: FittedBox(
                          fit: BoxFit.cover,
                          child: SizedBox(
                            width: controller.value.size.width,
                            height: controller.value.size.height,
                            child: VideoPlayer(controller),
                          ),
                        ),
                      )
                    : Container(
                        width: 200,
                        height: 200,
                        color: Colors.black,
                        child: const Center(
                          child: CircularProgressIndicator(
                            color: Color(0xFF4CAF50),
                          ),
                        ),
                      ),
                if (controller.value.isInitialized && !controller.value.isPlaying)
                  Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.5),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.play_arrow,
                      color: Colors.white,
                      size: 30,
                    ),
                  ),
                Positioned(
                  bottom: 8,
                  right: 8,
                  child: Row(
                    children: [
                      Text(
                        '${message.createdAt.hour.toString().padLeft(2, '0')}:${message.createdAt.minute.toString().padLeft(2, '0')}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          backgroundColor: Colors.black54,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () {
                          // Show full-screen video
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => Scaffold(
                                backgroundColor: Colors.black,
                                appBar: AppBar(
                                  backgroundColor: Colors.transparent,
                                  elevation: 0,
                                  leading: IconButton(
                                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                                    onPressed: () => Navigator.pop(context),
                                  ),
                                ),
                                body: Center(
                                  child: AspectRatio(
                                    aspectRatio: controller.value.aspectRatio,
                                    child: VideoPlayer(controller),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.5),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Icon(
                            Icons.fullscreen,
                            color: Colors.white,
                            size: 16,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildMessageInput() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
      decoration: BoxDecoration(
        color: Colors.grey[900],
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.add, color: Colors.grey),
            onPressed: () => _showMediaOptions(context),
            tooltip: 'Attach Media',
          ),
          Expanded(
            child: _isRecording
                ? Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.grey[800],
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.mic, color: Colors.redAccent, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: AudioWaveforms(
                            size: Size(MediaQuery.of(context).size.width * 0.6, 40),
                            recorderController: _recorderController,
                            waveStyle: const WaveStyle(
                              waveColor: Colors.white,
                              extendWaveform: true,
                              showMiddleLine: false,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12.0),
                              color: Colors.transparent,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : TextField(
                    controller: _messageController,
                    decoration: InputDecoration(
                      hintText: 'Type a message here...',
                      hintStyle: TextStyle(color: Colors.grey[400]),
                      filled: true,
                      fillColor: Colors.grey[800],
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24.0),
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
              ? Container(
                  decoration: const BoxDecoration(
                    color: Colors.redAccent,
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.stop, color: Colors.white),
                    onPressed: _stopRecordingAndSend,
                    tooltip: 'Stop Recording',
                  ),
                )
              : Container(
                  decoration: BoxDecoration(
                    color: _canSend ? const Color(0xFF4CAF50) : Colors.grey[700],
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    icon: Icon(
                      _canSend ? Icons.send : Icons.mic,
                      color: Colors.white,
                    ),
                    onPressed: _canSend ? _sendMessage : _startRecording,
                    tooltip: _canSend ? 'Send' : 'Record Audio',
                  ),
                ),
        ],
      ),
    );
  }

  void _showVideoPreview(File videoFile) {
    final videoPlayerController = VideoPlayerController.file(videoFile);
    
    videoPlayerController.initialize().then((_) {
      videoPlayerController.play();
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: Colors.grey[900],
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          contentPadding: const EdgeInsets.all(16),
          title: const Text(
            'Send Video',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AspectRatio(
                aspectRatio: videoPlayerController.value.aspectRatio,
                child: VideoPlayer(videoPlayerController),
              ),
              const SizedBox(height: 16),
              const Text(
                'Send this video?',
                style: TextStyle(color: Colors.white70),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                videoPlayerController.dispose();
                Navigator.pop(context);
              },
              style: TextButton.styleFrom(foregroundColor: Colors.grey),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                videoPlayerController.dispose();
                Navigator.pop(context);
                _sendVideoMessage();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4CAF50),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Send'),
            ),
          ],
        ),
      ).then((_) {
        videoPlayerController.dispose();
      });
    });
  }

  void _showAudioPreview(File audioFile) {
    final playerController = PlayerController();
    
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: Colors.grey[900],
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text(
              'Send Audio',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        playerController.playerState == PlayerState.playing
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_filled,
                        color: const Color(0xFF4CAF50),
                        size: 36,
                      ),
                      onPressed: () async {
                        try {
                          if (playerController.playerState == PlayerState.playing) {
                            await playerController.pausePlayer();
                          } else {
                            await playerController.preparePlayer(
                              path: audioFile.path,
                              shouldExtractWaveform: true,
                            );
                            await playerController.startPlayer();
                          }
                          setDialogState(() {});
                        } catch (e) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Failed to play audio: $e'),
                              backgroundColor: Colors.redAccent,
                            ),
                          );
                        }
                      },
                    ),
                    Expanded(
                      child: AudioFileWaveforms(
                        size: const Size(200, 40),
                        playerController: playerController,
                        playerWaveStyle: const PlayerWaveStyle(
                          fixedWaveColor: Colors.white54,
                          liveWaveColor: Colors.white,
                          scaleFactor: 150,
                          waveThickness: 2.5,
                          spacing: 3,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text(
                  'Send this audio message?',
                  style: TextStyle(color: Colors.white70),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  playerController.dispose();
                  Navigator.pop(context);
                },
                style: TextButton.styleFrom(foregroundColor: Colors.grey),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () async {
                  playerController.dispose();
                  Navigator.pop(context);
                  await _uploadAndSendAudio(audioFile);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4CAF50),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('Send'),
              ),
            ],
          );
        },
      ),
    ).then((_) {
      playerController.dispose();
    });
  }

  // New method to handle the actual upload and sending of audio
  Future<void> _uploadAndSendAudio(File file) async {
    setState(() {
      _isUploading = true;
    });

    try {
      final currentUser = await _authService.getCurrentUser();
      if (currentUser == null) throw Exception('User not authenticated');

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
        SnackBar(
          content: Text('Failed to send audio: $e'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    } finally {
      setState(() {
        _isUploading = false;
        _recordedFilePath = null;
      });
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.removeListener(_scrollListener);
    _scrollController.dispose();
    _messagesChannel?.unsubscribe();
    _recorderController.dispose();
    _cameraController?.dispose();
    _recordingTimer?.cancel();
    _animationController.dispose();
    for (var path in _localAudioPaths.values) {
      File(path).deleteSync();
    }
    for (var controller in _videoControllers.values) {
      controller.dispose();
    }
    _videoControllers.clear();
    super.dispose();
  }
}
