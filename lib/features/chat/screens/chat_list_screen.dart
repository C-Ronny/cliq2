import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _conversations = [];
  List<Map<String, dynamic>> _filteredConversations = [];

  @override
  void initState() {
    super.initState();
    // Mock data for now; will fetch from Supabase in Step 3
    _conversations = [
      {
        'friend_id': 'friend_1', // Add friend_id for navigation
        'friend_name': 'Ronelle Cudjoe',
        'last_message': 'Hey, how are you?',
        'timestamp': DateTime.now().subtract(const Duration(hours: 1)),
        'unread': true,
      },
      {
        'friend_id': 'friend_2',
        'friend_name': 'Jane Doe',
        'last_message': 'See you tomorrow!',
        'timestamp': DateTime.now().subtract(const Duration(days: 1)),
        'unread': false,
      },
    ];
    _filteredConversations = _conversations;

    _searchController.addListener(_filterConversations);
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

  @override
  void dispose() {
    _searchController.dispose();
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
      body: Column(
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
                ? const Center(
                    child: Text(
                      'No chats found.',
                      style: TextStyle(color: Colors.grey, fontSize: 16),
                    ),
                  )
                : ListView.builder(
                    itemCount: _filteredConversations.length,
                    itemBuilder: (context, index) {
                      final conversation = _filteredConversations[index];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Colors.grey[700],
                          child: Text(
                            conversation['friend_name']
                                    ?.substring(0, 1)
                                    .toUpperCase() ??
                                'U',
                            style: const TextStyle(color: Colors.white),
                          ),
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
                            },
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
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