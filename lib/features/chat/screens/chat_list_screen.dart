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

class ChatListScreenState extends State<ChatListScreen> {
  final TextEditingController _searchController = TextEditingController();
  final AuthService _authService = AuthService();
  List<Map<String, dynamic>> _conversations = [];
  List<Map<String, dynamic>> _filteredConversations = [];
  RealtimeChannel? _messagesChannel;
  String? _currentUserId;

  @override
  void initState() {
    super.initState();
    _initialize();
    _searchController.addListener(_filterConversations);
  }

  Future<void> _initialize() async {
    // Fetch the current user
    final currentUser = await _authService.getCurrentUser();
    if (currentUser == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('User not authenticated')),
      );
      context.go('/login');
      return;
    }
    setState(() {
      _currentUserId = currentUser.id;
    });

    await _fetchConversations();
    _setupRealtimeListener();
  }

  Future<void> _fetchConversations() async {
    if (_currentUserId == null) return;

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
          convList.add({
            'conversation_id': conv['id'],
            'friend_id': friendId,
            'friend_name': '${friendProfile['first_name'] ?? ''} ${friendProfile['last_name'] ?? ''}'.trim(),
            'friend_profile_picture': profilePictureUrl,
            'last_message': lastMessage.content.isNotEmpty ? lastMessage.content : (lastMessage.mediaType == 'image' ? 'Image' : ''),
            'timestamp': lastMessage.createdAt,
            'unread': false, // We'll implement unread logic later if needed
          });
        }
      }

      // Sort conversations by the timestamp of the last message (most recent first)
      convList.sort((a, b) => b['timestamp'].compareTo(a['timestamp']));

      setState(() {
        _conversations = convList;
        _filteredConversations = _conversations;
      });
    } catch (e) {
      print('Error fetching conversations: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load conversations: $e')),
      );
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Chats',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: const Color(0xFF4CAF50),
        elevation: 0,
      ),
      body: RefreshIndicator(
        onRefresh: _onRefresh,
        color: const Color(0xFF4CAF50),
        child: Column(
          children: [
            // Search Bar
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'Search chats...',
                  hintStyle: TextStyle(color: Colors.grey[400]),
                  prefixIcon: const Icon(Icons.search, color: Colors.grey),
                  filled: true,
                  fillColor: Colors.grey[200],
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12.0),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            // Chat List
            Expanded(
              child: _filteredConversations.isEmpty
                  ? Center(
                      child: SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: Container(
                          height: MediaQuery.of(context).size.height - 200, // Ensure enough height to enable scrolling
                          child: const Center(
                            child: Text(
                              'No chats found.',
                              style: TextStyle(color: Colors.grey, fontSize: 16),
                            ),
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount: _filteredConversations.length,
                      itemBuilder: (context, index) {
                        final conversation = _filteredConversations[index];
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Colors.grey[700],
                            backgroundImage: conversation['friend_profile_picture'] != null
                                ? NetworkImage(conversation['friend_profile_picture'])
                                : null,
                            child: conversation['friend_profile_picture'] == null
                                ? Text(
                                    conversation['friend_name']?.substring(0, 1).toUpperCase() ?? 'U',
                                    style: const TextStyle(color: Colors.white),
                                  )
                                : null,
                          ),
                          title: Text(
                            conversation['friend_name'] ?? 'Unknown',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: conversation['unread']
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                          subtitle: Text(
                            conversation['last_message'] ?? '',
                            style: TextStyle(
                              color: Colors.grey[400],
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                _formatTimestamp(conversation['timestamp']),
                                style: TextStyle(
                                  color: Colors.grey[400],
                                  fontSize: 12,
                                ),
                              ),
                              if (conversation['unread'])
                                Container(
                                  margin: const EdgeInsets.only(top: 4.0),
                                  width: 10,
                                  height: 10,
                                  decoration: const BoxDecoration(
                                    color: Color(0xFF4CAF50),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                            ],
                          ),
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
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      backgroundColor: Colors.grey[900],
    );
  }

  String _formatTimestamp(DateTime timestamp) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDate = DateTime(
      timestamp.year,
      timestamp.month,
      timestamp.day,
    );

    if (messageDate == today) {
      return '${timestamp.hour}:${timestamp.minute.toString().padLeft(2, '0')}';
    } else {
      return '${timestamp.day}/${timestamp.month}/${timestamp.year.toString().substring(2)}';
    }
  }
}