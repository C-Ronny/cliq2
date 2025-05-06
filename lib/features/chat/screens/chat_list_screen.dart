import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../auth/auth_service.dart';
import '../../../models/message_model.dart';
import '../../../config/supabase.dart';
import '../../../models/user_model.dart';

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
  bool _isSearching = false;

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
        
        // Check if this is a group chat (more than 2 participants)
        final isGroupChat = participantIds.length > 2;
        
        String friendId = '';
        String groupName = '';
        
        if (isGroupChat) {
          // For group chats, we'll need to fetch the group name from a separate table
          // This is a placeholder - you would implement this based on your data structure
          groupName = "Group Chat"; // Default name
          
          try {
            final groupData = await SupabaseConfig.client
                .from('group_chats')
                .select('name')
                .eq('conversation_id', conv['id'])
                .single();
            
            if (groupData != null && groupData['name'] != null) {
              groupName = groupData['name'];
            }
          } catch (e) {
            print('Failed to fetch group name: $e');
          }
        } else {
          // For one-on-one chats, get the other participant's ID
          friendId = participantIds.firstWhere((id) => id != _currentUserId);
        }

        // Fetch profiles based on chat type
        Map<String, dynamic> profileData = {};
        String? profilePictureUrl;
        
        if (isGroupChat) {
          // For group chats, we'll use the group name and a placeholder image
          profileData = {
            'id': conv['id'],
            'first_name': groupName,
            'last_name': '',
            'profile_picture': null // You might want to add group avatars
          };
        } else {
          // Fetch the friend's profile for one-on-one chats
          try {
            profileData = await SupabaseConfig.client
                .from('profiles')
                .select('id, first_name, last_name, profile_picture')
                .eq('id', friendId)
                .single();
                
            // Fetch signed URL for friend's profile picture if it exists
            if (profileData['profile_picture'] != null) {
              try {
                profilePictureUrl = await SupabaseConfig.client.storage
                    .from('avatars')
                    .createSignedUrl('$friendId.jpg', 60);
              } catch (e) {
                print('Failed to fetch signed URL for $friendId: $e');
              }
            }
          } catch (e) {
            print('Failed to fetch profile for $friendId: $e');
            continue; // Skip this conversation if we can't get the profile
          }
        }

        // Fetch the last message in this conversation
        final lastMessageResponse = await SupabaseConfig.client
            .from('messages')
            .select('*')
            .eq('conversation_id', conv['id'])
            .order('created_at', ascending: false)
            .limit(1)
            .maybeSingle();

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
          
          // Get sender name for group chats
          String senderPrefix = '';
          if (isGroupChat && lastMessage.senderId != _currentUserId) {
            try {
              final senderProfile = await SupabaseConfig.client
                  .from('profiles')
                  .select('first_name')
                  .eq('id', lastMessage.senderId)
                  .single();
              
              if (senderProfile != null && senderProfile['first_name'] != null) {
                senderPrefix = '${senderProfile['first_name']}: ';
              }
            } catch (e) {
              print('Failed to fetch sender name: $e');
            }
          }
          
          // Generate random unread count for demo purposes
          // In a real app, you would track this in your database
          final unreadCount = isGroupChat ? 
              (DateTime.now().millisecondsSinceEpoch % 10) : 
              (DateTime.now().millisecondsSinceEpoch % 5);
          
          convList.add({
            'conversation_id': conv['id'],
            'is_group': isGroupChat,
            'friend_id': isGroupChat ? '' : friendId,
            'friend_name': isGroupChat ? 
                groupName : 
                '${profileData['first_name'] ?? ''} ${profileData['last_name'] ?? ''}'.trim(),
            'friend_profile_picture': profilePictureUrl,
            'last_message': senderPrefix + displayMessage,
            'timestamp': lastMessage.createdAt,
            'is_sent_by_me': lastMessage.senderId == _currentUserId,
            'unread': unreadCount > 0, // For demo purposes
            'unread_count': unreadCount, // For demo purposes
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
        final lastMessage = conversation['last_message'].toString().toLowerCase();
        return friendName.contains(query) || lastMessage.contains(query);
      }).toList();
    });
  }

  Future<List<UserModel>> _fetchFriends() async {
    if (_currentUserId == null) return [];
    
    try {
      final friends = await _authService.getFriends();
      // Fetch profile pictures for each friend
      for (var friend in friends) {
        if (friend.profilePicture == null && friend.id.isNotEmpty) {
          try {
            final profilePictureUrl = await SupabaseConfig.client.storage
                .from('avatars')
                .createSignedUrl('${friend.id}.jpg', 60);
            friend.profilePicture = profilePictureUrl;
          } catch (e) {
            print('Failed to fetch profile picture for ${friend.id}: $e');
          }
        }
      }
      return friends;
    } catch (e) {
      print('Error fetching friends: $e');
      return [];
    }
  }

  Future<void> _createOrGetConversation(String friendId, String friendName) async {
    if (_currentUserId == null) return;
    
    try {
      // Check if conversation already exists
      final existingConvResponse = await SupabaseConfig.client
          .from('conversations')
          .select('id')
          .contains('participant_ids', [_currentUserId, friendId])
          .maybeSingle();
    
      String conversationId;
    
      if (existingConvResponse != null) {
        // Conversation exists
        conversationId = existingConvResponse['id'];
      } else {
        // Create new conversation
        final newConvResponse = await SupabaseConfig.client
            .from('conversations')
            .insert({
              'participant_ids': [_currentUserId, friendId],
              'created_at': DateTime.now().toIso8601String(),
            })
            .select('id')
            .single();
        
        conversationId = newConvResponse['id'];
      }
    
      // Navigate to chat screen
      if (mounted) {
        context.go(
          '/chat/$friendId',
          extra: {
            'friendName': friendName,
            'friendId': friendId,
            'conversationId': conversationId,
          },
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to create conversation: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  void _showNewConversationDialog() async {
    final friends = await _fetchFriends();
    
    if (!mounted) return;
    
    if (friends.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('You don\'t have any friends yet. Add friends to start chatting!'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          final TextEditingController searchController = TextEditingController();
          List<UserModel> filteredFriends = List.from(friends);
          
          void filterFriends(String query) {
            setState(() {
              filteredFriends = friends.where((friend) {
                final fullName = '${friend.firstName ?? ''} ${friend.lastName ?? ''}'.toLowerCase();
                final username = (friend.username ?? '').toLowerCase();
                return fullName.contains(query.toLowerCase()) || 
                       username.contains(query.toLowerCase());
              }).toList();
            });
          }
          
          searchController.addListener(() {
            filterFriends(searchController.text);
          });
          
          return DraggableScrollableSheet(
            initialChildSize: 0.7,
            minChildSize: 0.5,
            maxChildSize: 0.9,
            expand: false,
            builder: (_, scrollController) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      height: 5,
                      width: 40,
                      margin: const EdgeInsets.only(top: 12, bottom: 16),
                      decoration: BoxDecoration(
                        color: Colors.grey[600],
                        borderRadius: BorderRadius.circular(2.5),
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 20.0),
                    child: Text(
                      'New Conversation',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
                    child: Container(
                      height: 50,
                      decoration: BoxDecoration(
                        color: Colors.grey[800],
                        borderRadius: BorderRadius.circular(25),
                      ),
                      child: TextField(
                        controller: searchController,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: 'Search friends...',
                          hintStyle: TextStyle(color: Colors.grey[400]),
                          prefixIcon: const Icon(Icons.search, color: Colors.grey),
                          suffixIcon: searchController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, color: Colors.grey),
                                  onPressed: () {
                                    searchController.clear();
                                    filterFriends('');
                                  },
                                )
                              : null,
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16.0,
                            vertical: 14.0,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: filteredFriends.isEmpty
                        ? Center(
                            child: Text(
                              'No friends found',
                              style: TextStyle(color: Colors.grey[400]),
                            ),
                          )
                        : ListView.builder(
                            controller: scrollController,
                            itemCount: filteredFriends.length,
                            itemBuilder: (context, index) {
                              final friend = filteredFriends[index];
                              final friendName = '${friend.firstName ?? ''} ${friend.lastName ?? ''}'.trim();
                              return ListTile(
                                leading: CircleAvatar(
                                  radius: 24,
                                  backgroundColor: Colors.grey[700],
                                  backgroundImage: friend.profilePicture != null
                                      ? NetworkImage(friend.profilePicture!)
                                      : null,
                                  child: friend.profilePicture == null
                                      ? Text(
                                          (friend.firstName ?? 'U').substring(0, 1).toUpperCase(),
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 18,
                                          ),
                                        )
                                      : null,
                                ),
                                title: Text(
                                  friendName,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                subtitle: friend.username != null
                                  ? Text(
                                      '@${friend.username}',
                                      style: TextStyle(
                                        color: Colors.grey[400],
                                        fontSize: 12,
                                      ),
                                    )
                                  : null,
                                onTap: () {
                                  Navigator.pop(context);
                                  _createOrGetConversation(friend.id, friendName);
                                },
                              );
                            },
                          ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _onRefresh() async {
    await _fetchConversations();
  }

  void _toggleSearch() {
    setState(() {
      _isSearching = !_isSearching;
      if (!_isSearching) {
        _searchController.clear();
        _filteredConversations = _conversations;
      }
    });
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
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        centerTitle: true,
        title: const Text(
          'Chats',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 24,
          ),
        ),
      ),
      body: Column(
        children: [
          // Search Bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Container(
              height: 50,
              decoration: BoxDecoration(
                color: Colors.grey[800],
                borderRadius: BorderRadius.circular(25),
              ),
              child: TextField(
                controller: _searchController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Search chats...',
                  hintStyle: TextStyle(color: Colors.grey[400]),
                  prefixIcon: const Icon(Icons.search, color: Colors.grey),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, color: Colors.grey),
                          onPressed: () {
                            _searchController.clear();
                            _filterConversations();
                          },
                        )
                      : null,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16.0,
                    vertical: 14.0,
                  ),
                ),
                onChanged: (value) {
                  _filterConversations();
                },
              ),
            ),
          ),
          
          // Chat List
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(
                      color: Color(0xFF4CAF50),
                    ),
                  )
                : _isError
                    ? _buildErrorView()
                    : _buildConversationsList(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showNewConversationDialog,
        backgroundColor: const Color(0xFF4CAF50),
        child: const Icon(Icons.chat, color: Colors.white),
      ),
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
              _searchController.text.isNotEmpty
                  ? 'No conversations found'
                  : 'No conversations yet',
              style: TextStyle(color: Colors.grey[400], fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text(
              _searchController.text.isNotEmpty
                  ? 'Try a different search term'
                  : 'Start chatting with your friends',
              style: TextStyle(color: Colors.grey[600], fontSize: 14),
            ),
            if (_searchController.text.isEmpty) ...[
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _showNewConversationDialog,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4CAF50),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('Start a new conversation'),
              ),
            ],
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _onRefresh,
      color: const Color(0xFF4CAF50),
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: ListView.separated(
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: _filteredConversations.length,
          separatorBuilder: (context, index) => const Divider(
            color: Color(0xFF333333),
            height: 1,
            indent: 80,
          ),
          itemBuilder: (context, index) {
            return _buildConversationTile(_filteredConversations[index]);
          },
        ),
      ),
    );
  }

  Widget _buildConversationTile(Map<String, dynamic> conversation) {
    return InkWell(
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
                    style: const TextStyle(
                      color: Color(0xFF4CAF50),
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    conversation['last_message'] ?? '',
                    style: TextStyle(
                      color: conversation['unread'] ? Colors.white70 : Colors.grey[500],
                      fontSize: 14,
                      fontWeight: conversation['unread'] ? FontWeight.w500 : FontWeight.normal,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
                    color: conversation['unread'] ? Colors.white : Colors.grey[500],
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 4),
                if (conversation['unread'])
                  Container(
                    width: 24,
                    height: 24,
                    decoration: const BoxDecoration(
                      color: Color(0xFF4CAF50),
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text(
                        '${conversation['unread_count']}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
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
      return 'Today';
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
