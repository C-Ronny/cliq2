import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import '../../auth/auth_service.dart';
import '../../../config/supabase.dart';
import '../../../models/message_model.dart';

class ChatScreen extends StatefulWidget {
  final String friendName;
  final String friendId;

  const ChatScreen({
    super.key,
    required this.friendName,
    required this.friendId,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final AuthService _authService = AuthService();
  final ScrollController _scrollController = ScrollController();
  final ImagePicker _picker = ImagePicker();
  List<MessageModel> _messages = [];
  RealtimeChannel? _messagesChannel;
  bool _canSend = false;
  String? _conversationId;
  String? _currentUserId;
  bool _isLoading = true;
  bool _isUploading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _messageController.addListener(() {
      setState(() {
        _canSend = _messageController.text.trim().isNotEmpty;
      });
    });
    _initialize();
  }

  Future<void> _initialize() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await _fetchCurrentUser();
      await _fetchOrCreateConversation();
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

  Future<void> _fetchOrCreateConversation() async {
    try {
      final currentUser = await _authService.getCurrentUser();
      if (currentUser == null) {
        throw Exception('User not authenticated');
      }

      final response = await SupabaseConfig.client
          .from('conversations')
          .select('id')
          .contains('participant_ids', [currentUser.id, widget.friendId])
          .maybeSingle();

      if (response != null && response['id'] != null) {
        _conversationId = response['id'];
      } else {
        final newConversation = await _authService.createConversation([currentUser.id, widget.friendId]);
        _conversationId = newConversation['id'];
      }

      await _fetchMessages();
    } catch (e) {
      throw Exception('Failed to load or create conversation: $e');
    }
  }

  Future<void> _fetchMessages() async {
    if (_conversationId == null) return;
    try {
      final response = await SupabaseConfig.client
          .from('messages')
          .select('*')
          .eq('conversation_id', _conversationId!)
          .order('created_at', ascending: true);
      setState(() {
        _messages = (response as List).map((json) => MessageModel.fromJson(json)).toList();
      });
      _scrollToBottom();
    } catch (e) {
      throw Exception('Failed to load messages: $e');
    }
  }

  void _setupRealtimeListener() {
    if (_conversationId == null) return;

    _messagesChannel?.unsubscribe();
    _messagesChannel = SupabaseConfig.client.channel('messages_$_conversationId')
      ..onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'conversation_id',
            value: _conversationId!,
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
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
    if (!_canSend || _conversationId == null) return;
    final currentUser = await _authService.getCurrentUser();
    if (currentUser == null) return;

    final message = MessageModel(
      id: '',
      content: _messageController.text.trim(),
      senderId: currentUser.id,
      createdAt: DateTime.now(),
      conversationId: _conversationId!,
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

  Future<void> _sendImageMessage() async {
    if (_conversationId == null) return;
    final currentUser = await _authService.getCurrentUser();
    if (currentUser == null) {
      print('DEBUG: User not authenticated - _authService.getCurrentUser() returned null');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('User not authenticated')),
      );
      return;
    }

    // Debug: Check Supabase client session
    final session = SupabaseConfig.client.auth.currentSession;
    print('DEBUG: Supabase session: ${session != null ? "Active" : "Not active"}');
    print('DEBUG: Authenticated user ID: ${currentUser.id}');

    setState(() {
      _isUploading = true;
      _errorMessage = null;
    });

    try {
      // Verify the conversation exists
      final conversation = await SupabaseConfig.client
          .from('conversations')
          .select('id')
          .eq('id', _conversationId!)
          .single();
      if (conversation == null) throw Exception('Conversation not found');

      // Pick image from gallery
      final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
      if (image == null) return; // User cancelled

      // Upload image to Supabase Storage
      final file = File(image.path);
      final fileName = '${DateTime.now().millisecondsSinceEpoch}_${currentUser.id}.jpg';
      print('DEBUG: Attempting to upload file: $fileName to chat-media bucket');
      await SupabaseConfig.client.storage
          .from('chat-media')
          .upload(fileName, file, fileOptions: const FileOptions(contentType: 'image/jpeg'));

      // Get the public URL of the uploaded image (for logging)
      final imageUrl = SupabaseConfig.client.storage
          .from('chat-media')
          .getPublicUrl(fileName);
      print('DEBUG: Image URL: $imageUrl');

      // Create a message with the image URL
      final message = MessageModel(
        id: '',
        content: '', // No text content for image messages
        senderId: currentUser.id,
        createdAt: DateTime.now(),
        conversationId: _conversationId!,
        mediaType: 'image',
        mediaUrl: fileName, // Store just the file name
      );

      // Insert the message into the database
      await SupabaseConfig.client.from('messages').insert(message.toJson());
    } catch (e) {
      print('DEBUG: Upload failed with error: $e');
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
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Audio sending not yet implemented')),
                  );
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () {
            context.go('/main/chats');
          },
        ),
        title: Text(
          widget.friendName,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        backgroundColor: const Color(0xFF4CAF50),
        elevation: 0,
      ),
      body: Column(
        children: [
          Expanded(
            child: _buildMessagesList(),
          ),
          _buildMessageInput(),
        ],
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
      );
    }

    if (_messages.isEmpty && !_isUploading) {
      return Center(
        child: Text(
          'No messages yet. Start chatting with ${widget.friendName}!',
          style: TextStyle(color: Colors.grey[400], fontSize: 16),
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
                        future: SupabaseConfig.client.storage
                            .from('chat-media')
                            .createSignedUrl(message.mediaUrl!, 60), // URL valid for 60 seconds
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
            child: TextField(
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
          IconButton(
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
    _scrollController.dispose();
    _messagesChannel?.unsubscribe();
    super.dispose();
  }
}