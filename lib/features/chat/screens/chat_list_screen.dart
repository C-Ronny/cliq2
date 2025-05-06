import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../auth/auth_service.dart';
import '../../../models/message_model.dart';
import '../../../config/supabase.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  ChatListScreenState createState() => ChatListScreenState();
}

class ChatListScreenState extends State<ChatListScreen> with SingleTickerProviderStateMixin {
  final TextEditingController _searchController = TextEditingController();
  final AuthService _authService = AuthService();
  List<Map<String, dynamic>> _conversations = [];
  List<Map<String, dynamic>> _filteredConversations = [];
  RealtimeChannel? _messagesChannel;
  String? _currentUserId;
  bool _isLoading = true;
  bool _isError = false;
  String? _errorMessage;
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeIn),
    );
    _initialize();
    _searchController.addListener(_filterConversations);
  }

  Future<void> _initialize() async {
    try {
      // Fetch the current user
      final currentUser = await _authService.getCurrentUser();
      if (currentUser == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('User not authenticated'),
            backgroundColor: Colors.redAccent,
          ),
        );
        context.go('/login');
        return;
      }
      setState(() {
        _currentUserId = currentUser.id;
      });

      await _fetchConversations();
      _setupRealtimeListener();
      _animationController.forward();
    } catch (e) {
      setState(() {
        _isError = true;
        _errorMessage = 'Failed to initialize: $e';
      });
    }
  }

  Future<void> _fetchConversations() async {
    if (_currentUserId == null) return;

    setState(() {
      _isLoading = true;
      _isError = false;
    });

    try {
      // Fetch conversations where the current user is a participant
      final response = await SupabaseConfig.client
          .from('conversations')
          .select('id, participant_ids')
          .contains('participant_ids', [_currentUserId]);

      final conversations = (response as List<dynamic>);

      List<Map<String, dynamic>> convList = [];
      for (var conv in conversations) {
        final participantIds = List<String>.from(conv['participant_ids']);
        final friendId = participantIds.firstWhere((id) => id != _currentUserId);

        // Fetch the friend's profile
        final friendProfile = await SupabaseConfig.client
            .from('profiles')
            .select('id, first_name, last_name, profile_picture')
            .eq('id', friendId)
            .single();

        // Fetch the last message in this conversation
        final lastMessageResponse = await SupabaseConfig.client
            .from('messages')
            .select('*')
            .eq('conversation_id', conv['id'])
            .order('created_at', ascending: false)
            .limit(1)
            .maybeSingle();

        // Fetch signed URL for friend's profile picture if it exists
        String? profilePictureUrl;
        if (friendProfile['profile_picture'] != null) {
          try {
            profilePictureUrl = await SupabaseConfig.client.storage
                .from('avatars')
                .createSignedUrl('$friendId.jpg', 60);
          } catch (e) {
            print('Failed to fetch signed URL for $friendId: $e');
          }
        }

        // Only add the conversation if it has at least one message
        if (lastMessageResponse != null) {
          final lastMessage = MessageModel.fromJson(lastMessageResponse);
          String displayMessage = '';
          
          // Format the message preview based on media type
          if (lastMessage.content.isNotEmpty) {
            displayMessage = lastMessage.content;
          } else if (lastMessage.mediaType == 'image') {
            displayMessage = '📷 Image';
          } else if (lastMessage.mediaType == 'audio') {
            displayMessage = '🎵 Audio message';
          } else if (lastMessage.mediaType == 'video') {
            displayMessage = '🎥 Video message';
          }
          
          convList.add({
            'conversation_id': conv['id'],
            'friend_id': friendId,
            'friend_name': '${friendProfile['first_name'] ?? ''} ${friendProfile['last_name'] ?? ''}'.trim(),
            'friend_profile_picture': profilePictureUrl,
            'last_message': displayMessage,
            'timestamp': lastMessage.createdAt,
            'is_sent_by_me': lastMessage.senderId == _currentUserId,
            'unread': false, // We'll implement unread logic later if needed
          });
        }
      }

      // Sort conversations by the timestamp of the last message (most recent first)
      convList.sort((a, b) => b['timestamp'].compareTo(a['timestamp']));

      setState(() {
        _conversations = convList;
        _filteredConversations = _conversations;
        _isLoading = false;
      });
    } catch (e) {
      print('Error fetching conversations: $e');
      setState(() {
        _isLoading = false;
        _isError = true;
        _errorMessage = 'Failed to load conversations';
      });
    }
  }

  void _setupRealtimeListener() {
    if (_currentUserId == null) return;

    _messagesChannel?.unsubscribe();
    _messagesChannel = SupabaseConfig.client.channel('all_messages')
      ..onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          callback: (payload) async {
            final newMessage = MessageModel.fromJson(payload.newRecord);
            // Check if the message belongs to a conversation involving the current user
            final convResponse = await SupabaseConfig.client
                .from('conversations')
                .select('id, participant_ids')
                .eq('id', newMessage.conversationId)
                .contains('participant_ids', [_currentUserId])
                .maybeSingle();

            if (convResponse != null) {
              // Refresh the conversations list
              await _fetchConversations();
            }
          })
      ..subscribe();
  }

  void _filterConversations() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      _filteredConversations = _conversations.where((conversation) {
        final friendName = conversation['friend_name'].toString().toLowerCase();
        return friendName.contains(query);
      }).toList();
    });
  }

  Future<void> _onRefresh() async {
    await _fetchConversations();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _messagesChannel?.unsubscribe();
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Chats',
          style: TextStyle(
            color: Colors.white, 
            fontWeight: FontWeight.bold,
            fontSize: 24,
          ),
        ),
        backgroundColor: const Color(0xFF4CAF50),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.search, color: Colors.white),
            onPressed: () {
              // Focus on search field
              FocusScope.of(context).requestFocus(FocusNode());
              showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                backgroundColor: Colors.grey[900],
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                ),
                builder: (context) => _buildSearchSheet(),
              );
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(
                color: Color(0xFF4CAF50),
              ),
            )
          : _isError
              ? _buildErrorView()
              : _buildConversationsList(),
      backgroundColor: Colors.grey[900],
    );
  }

  Widget _buildSearchSheet() {
    return DraggableScrollableSheet(
      initialChildSize: 0.9,
      minChildSize: 0.5,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return Padding(
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
              TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Search conversations...',
                  hintStyle: TextStyle(color: Colors.grey[400]),
                  prefixIcon: const Icon(Icons.search, color: Color(0xFF4CAF50)),
                  filled: true,
                  fillColor: Colors.grey[800],
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12.0),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16.0,
                    vertical: 14.0,
                  ),
                ),
                style: const TextStyle(color: Colors.white),
                onChanged: (value) {
                  _filterConversations();
                },
              ),
              const SizedBox(height: 16),
              Expanded(
                child: _filteredConversations.isEmpty
                    ? Center(
                        child: Text(
                          'No conversations found',
                          style: TextStyle(color: Colors.grey[400]),
                        ),
                      )
                    : ListView.builder(
                        controller: scrollController,
                        itemCount: _filteredConversations.length,
                        itemBuilder: (context, index) {
                          return _buildConversationTile(_filteredConversations[index]);
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.error_outline,
            color: Colors.redAccent,
            size: 48,
          ),
          const SizedBox(height: 16),
          Text(
            _errorMessage ?? 'Something went wrong',
            style: const TextStyle(color: Colors.white, fontSize: 16),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _initialize,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF4CAF50),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Widget _buildConversationsList() {
    if (_filteredConversations.isEmpty) {
      return Center(
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
              'No conversations yet',
              style: TextStyle(color: Colors.grey[400], fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text(
              'Start chatting with your friends',
              style: TextStyle(color: Colors.grey[600], fontSize: 14),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () {
                context.go('/main/friends');
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4CAF50),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('Find Friends'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _onRefresh,
      color: const Color(0xFF4CAF50),
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: _filteredConversations.length,
          itemBuilder: (context, index) {
            return _buildConversationTile(_filteredConversations[index]);
          },
        ),
      ),
    );
  }

  Widget _buildConversationTile(Map<String, dynamic> conversation) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 8.0),
      child: Card(
        color: Colors.grey[850],
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        child: InkWell(
          onTap: () {
            context.go(
              '/chat/${conversation['friend_id']}',
              extra: {
                'friendName': conversation['friend_name'],
                'friendId': conversation['friend_id'],
                'conversationId': conversation['conversation_id'],
              },
            );
          },
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12.0, horizontal: 16.0),
            child: Row(
              children: [
                // Profile picture
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.grey[700],
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: conversation['friend_profile_picture'] != null
                      ? ClipOval(
                          child: Image.network(
                            conversation['friend_profile_picture'],
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) => Center(
                              child: Text(
                                conversation['friend_name']?.substring(0, 1).toUpperCase() ?? 'U',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        )
                      : Center(
                          child: Text(
                            conversation['friend_name']?.substring(0, 1).toUpperCase() ?? 'U',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                ),
                const SizedBox(width: 16),
                // Conversation details
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        conversation['friend_name'] ?? 'Unknown',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: conversation['unread'] ? FontWeight.bold : FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          if (conversation['is_sent_by_me'])
                            const Padding(
                              padding: EdgeInsets.only(right: 4.0),
                              child: Icon(
                                Icons.check,
                                size: 14,
                                color: Color(0xFF4CAF50),
                              ),
                            ),
                          Expanded(
                            child: Text(
                              conversation['last_message'] ?? '',
                              style: TextStyle(
                                color: conversation['unread'] ? Colors.white70 : Colors.grey[400],
                                fontSize: 14,
                                fontWeight: conversation['unread'] ? FontWeight.w500 : FontWeight.normal,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                // Timestamp and unread indicator
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      _formatTimestamp(conversation['timestamp']),
                      style: TextStyle(
                        color: conversation['unread'] ? const Color(0xFF4CAF50) : Colors.grey[500],
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    if (conversation['unread'])
                      Container(
                        width: 18,
                        height: 18,
                        decoration: const BoxDecoration(
                          color: Color(0xFF4CAF50),
                          shape: BoxShape.circle,
                        ),
                        child: const Center(
                          child: Text(
                            '1',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatTimestamp(DateTime timestamp) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = DateTime(now.year, now.month, now.day - 1);
    final messageDate = DateTime(
      timestamp.year,
      timestamp.month,
      timestamp.day,
    );

    if (messageDate == today) {
      return '${timestamp.hour}:${timestamp.minute.toString().padLeft(2, '0')}';
    } else if (messageDate == yesterday) {
      return 'Yesterday';
    } else if (now.difference(timestamp).inDays < 7) {
      // Return day of week for messages within the last week
      final weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
      return weekdays[timestamp.weekday - 1];
    } else {
      return '${timestamp.day}/${timestamp.month}/${timestamp.year.toString().substring(2)}';
    }
  }
}
