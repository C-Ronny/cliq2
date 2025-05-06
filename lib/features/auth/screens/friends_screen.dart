import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../auth/auth_service.dart';
import '../../../models/user_model.dart';
import 'dart:async';

class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key});
  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> with SingleTickerProviderStateMixin {
  final _authService = AuthService();
  List<UserModel> _friends = [];
  List<Map<String, dynamic>> _friendRequests = [];
  List<UserModel> _searchResults = [];
  String? _errorMessage;
  bool _isLoadingFriends = false;
  bool _isLoadingRequests = false;
  bool _isSearching = false;
  final _searchController = TextEditingController();
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  Timer? _debounce;
  Set<String> _friendIds = {};
  Set<String> _requestIds = {};
  late final RealtimeChannel _friendsChannel;
  late final RealtimeChannel _requestsChannel;
  int _selectedTabIndex = 0;
  final GlobalKey<RefreshIndicatorState> _refreshIndicatorKey = GlobalKey<RefreshIndicatorState>();

  @override
  void initState() {
    super.initState();
    _fetchFriends();
    _fetchFriendRequests();
    _setupRealtimeListeners();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
    _animationController.forward();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _animationController.dispose();
    _friendsChannel.unsubscribe();
    _requestsChannel.unsubscribe();
    super.dispose();
  }

  void _setupRealtimeListeners() {
    final currentUser = _authService.supabase.auth.currentUser;
    if (currentUser == null) return;

    _friendsChannel = _authService.supabase.channel('friends_${currentUser.id}')
      ..onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'friendships',
          callback: (payload) {
            final newFriendId = payload.newRecord['friend_id'] as String;
            if (newFriendId != currentUser.id) {
              _fetchFriends(); // Refresh friends list
            }
          })
      ..onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'friendships',
          callback: (payload) {
            final removedFriendId = payload.oldRecord['friend_id'] as String;
            if (removedFriendId != currentUser.id) {
              _fetchFriends(); // Refresh friends list
            }
          })
      ..subscribe();

    _requestsChannel = _authService.supabase.channel('requests_${currentUser.id}')
      ..onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'friend_requests',
          callback: (payload) {
            if (payload.newRecord['to_user_id'] == currentUser.id &&
                payload.newRecord['status'] == 'pending') {
              _fetchFriendRequests(); // Refresh requests list
            }
          })
      ..onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'friend_requests',
          callback: (payload) {
            if (payload.newRecord['to_user_id'] == currentUser.id &&
                payload.newRecord['status'] != 'pending') {
              _fetchFriendRequests(); // Refresh requests list
            }
          })
      ..subscribe();
  }

  Future<void> _fetchFriends() async {
    setState(() {
      _isLoadingFriends = true;
      _errorMessage = null;
    });

    try {
      final startTime = DateTime.now();
      final friends = await _authService.getFriends();
      final duration = DateTime.now().difference(startTime);
      print('Fetching friends took: ${duration.inMilliseconds}ms');

      setState(() {
        _friends = friends;
        _friendIds = friends.map((friend) => friend.id).toSet();
        _isLoadingFriends = false;
      });

      // Load profile pictures asynchronously
      for (var friend in _friends) {
        _authService.fetchProfilePicture(friend);
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to load friends: ${e.toString().replaceFirst('Exception: ', '')}';
        _isLoadingFriends = false;
      });
    }
  }

  Future<void> _fetchFriendRequests() async {
    setState(() {
      _isLoadingRequests = true;
      _errorMessage = null;
    });

    try {
      final startTime = DateTime.now();
      final friendRequests = await _authService.getFriendRequests();
      final duration = DateTime.now().difference(startTime);
      print('Fetching friend requests took: ${duration.inMilliseconds}ms');

      setState(() {
        _friendRequests = friendRequests;
        _requestIds = friendRequests
            .map((request) => (request['sender'] as UserModel).id)
            .toSet();
        _isLoadingRequests = false;
      });

      // Load profile pictures asynchronously
      for (var request in _friendRequests) {
        _authService.fetchProfilePicture(request['sender'] as UserModel);
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to load friend requests: ${e.toString().replaceFirst('Exception: ', '')}';
        _isLoadingRequests = false;
      });
    }
  }

  Future<void> _fetchData() async {
    await Future.wait([
      _fetchFriends(),
      _fetchFriendRequests(),
    ]);
  }

  Future<void> _searchUsers(String query) async {
    if (query.isEmpty) {
      setState(() {
        _searchResults = [];
        _isSearching = false;
      });
      return;
    }

    setState(() {
      _isSearching = true;
      _errorMessage = null;
    });

    try {
      print('Searching for: $query');
      final startTime = DateTime.now();
      final results = await _authService.searchUsers(
        query: query,
        friendIds: _friendIds,
        requestIds: _requestIds,
      );
      final searchDuration = DateTime.now().difference(startTime);
      print('Search took: ${searchDuration.inMilliseconds}ms');

      setState(() {
        _searchResults = results;
        _isSearching = false;
      });

      // Load profile pictures asynchronously
      for (var user in _searchResults) {
        _authService.fetchProfilePicture(user);
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Search failed: ${e.toString().replaceFirst('Exception: ', '')}';
        _isSearching = false;
      });
      print('Search error: $e');
    }
  }

  void _onSearchChanged(String query) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _searchUsers(query);
    });
  }

  Future<void> _sendFriendRequest(String userId) async {
    try {
      await _authService.sendFriendRequest(userId);
      setState(() {
        _searchResults = _searchResults.where((user) => user.id != userId).toList();
        _requestIds.add(userId);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              Icon(Icons.check_circle_outline, color: Colors.white),
              SizedBox(width: 8),
              Text('Friend request sent!'),
            ],
          ),
          backgroundColor: Color(0xFF4CAF50),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 3),
        ),
      );
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to send request: ${e.toString().replaceFirst('Exception: ', '')}';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Failed to send request: ${e.toString().replaceFirst('Exception: ', '')}'),
              ),
            ],
          ),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _acceptFriendRequest(String requestId) async {
    try {
      await _authService.acceptFriendRequest(requestId);
      await _fetchData();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              Icon(Icons.check_circle_outline, color: Colors.white),
              SizedBox(width: 8),
              Text('Friend request accepted!'),
            ],
          ),
          backgroundColor: Color(0xFF4CAF50),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 3),
        ),
      );
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to accept request: ${e.toString().replaceFirst('Exception: ', '')}';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Failed to accept request: ${e.toString().replaceFirst('Exception: ', '')}'),
              ),
            ],
          ),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _declineFriendRequest(String requestId) async {
    try {
      await _authService.declineFriendRequest(requestId);
      await _fetchData();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              Icon(Icons.check_circle_outline, color: Colors.white),
              SizedBox(width: 8),
              Text('Friend request declined'),
            ],
          ),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 3),
        ),
      );
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to decline request: ${e.toString().replaceFirst('Exception: ', '')}';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Failed to decline request: ${e.toString().replaceFirst('Exception: ', '')}'),
              ),
            ],
          ),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _removeFriend(String friendId) async {
    try {
      await _authService.removeFriend(friendId);
      await _fetchData();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              Icon(Icons.check_circle_outline, color: Colors.white),
              SizedBox(width: 8),
              Text('Friend removed'),
            ],
          ),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 3),
        ),
      );
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to remove friend: ${e.toString().replaceFirst('Exception: ', '')}';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Failed to remove friend: ${e.toString().replaceFirst('Exception: ', '')}'),
              ),
            ],
          ),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _showRemoveFriendDialog(UserModel friend) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: const Text(
          'Remove Friend',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          'Are you sure you want to remove ${friend.firstName ?? 'this person'} from your friends list?',
          style: const TextStyle(color: Color(0xFFB3B3B3)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Color(0xFFB3B3B3)),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _removeFriend(friend.id);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }

  Future<void> _createChat(String friendId) async {
    try {
      final currentUser = await _authService.getCurrentUser();
      if (currentUser == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('User not authenticated'),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      // Check if a conversation already exists
      final response = await _authService.supabase
          .from('conversations')
          .select('id')
          .contains('participant_ids', [currentUser.id, friendId])
          .maybeSingle();

      String conversationId;
      if (response != null && response['id'] != null) {
        conversationId = response['id'];
      } else {
        final newConversation = await _authService.createConversation([currentUser.id, friendId]);
        conversationId = newConversation['id'];
      }

      final friend = _friends.firstWhere((f) => f.id == friendId);

      // Navigate to the chat screen
      context.go(
        '/chat/$friendId',
        extra: {
          'friendName': '${friend.firstName ?? ''} ${friend.lastName ?? ''}',
          'friendId': friendId,
          'conversationId': conversationId,
        },
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Failed to start chat: ${e.toString().replaceFirst('Exception: ', '')}'),
              ),
            ],
          ),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _viewFriendProfile(UserModel friend) {
    context.go('/friend/${friend.id}', extra: friend);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        centerTitle: true,
        title: const Text(
          'Friends',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 20,
          ),
        ),
      ),
      body: RefreshIndicator(
        key: _refreshIndicatorKey,
        onRefresh: _fetchData,
        color: const Color(0xFF4CAF50),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Stack(
            children: [
              Column(
                children: [
                  const SizedBox(height: 16),
                  // Search bar with improved styling
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1E1E),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.1),
                            blurRadius: 10,
                            offset: const Offset(0, 5),
                          ),
                        ],
                      ),
                      child: TextField(
                        controller: _searchController,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: 'Search users...',
                          hintStyle: const TextStyle(color: Color(0xFFB3B3B3)),
                          filled: true,
                          fillColor: Colors.transparent,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide.none,
                          ),
                          prefixIcon: const Icon(
                            Icons.search,
                            color: Color(0xFF4CAF50),
                          ),
                          suffixIcon: _searchController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, color: Color(0xFFB3B3B3)),
                                  onPressed: () {
                                    _searchController.clear();
                                    _searchUsers('');
                                  },
                                )
                              : null,
                          contentPadding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        onChanged: _onSearchChanged,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  // Custom tab bar
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: Container(
                      height: 60,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1E1E),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onTap: () {
                                setState(() {
                                  _selectedTabIndex = 0;
                                });
                              },
                              child: Container(
                                decoration: BoxDecoration(
                                  color: _selectedTabIndex == 0
                                      ? const Color(0xFF4CAF50).withOpacity(0.2)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      _friends.length.toString(),
                                      style: TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.bold,
                                        color: _selectedTabIndex == 0
                                            ? const Color(0xFF4CAF50)
                                            : Colors.white,
                                      ),
                                    ),
                                    Text(
                                      'Friends',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: _selectedTabIndex == 0
                                            ? const Color(0xFF4CAF50)
                                            : const Color(0xFFB3B3B3),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: GestureDetector(
                              onTap: () {
                                setState(() {
                                  _selectedTabIndex = 1;
                                });
                              },
                              child: Container(
                                decoration: BoxDecoration(
                                  color: _selectedTabIndex == 1
                                      ? const Color(0xFF4CAF50).withOpacity(0.2)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          _friendRequests.length.toString(),
                                          style: TextStyle(
                                            fontSize: 20,
                                            fontWeight: FontWeight.bold,
                                            color: _selectedTabIndex == 1
                                                ? const Color(0xFF4CAF50)
                                                : Colors.white,
                                          ),
                                        ),
                                        Text(
                                          'Requests',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: _selectedTabIndex == 1
                                                ? const Color(0xFF4CAF50)
                                                : const Color(0xFFB3B3B3),
                                          ),
                                        ),
                                      ],
                                    ),
                                    if (_friendRequests.isNotEmpty && _selectedTabIndex != 1)
                                      Positioned(
                                        top: 8,
                                        right: 30,
                                        child: Container(
                                          width: 10,
                                          height: 10,
                                          decoration: const BoxDecoration(
                                            color: Color(0xFF4CAF50),
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  // Content based on selected tab
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: _selectedTabIndex == 0
                        ? _buildFriendsTab()
                        : _buildRequestsTab(),
                  ),
                  if (_errorMessage != null && _searchResults.isEmpty) ...[
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24.0),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.redAccent.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.error_outline,
                              color: Colors.redAccent,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _errorMessage!,
                                style: const TextStyle(
                                  color: Colors.redAccent,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 80),
                ],
              ),
              // Search results overlay
              if (_isSearching || _searchResults.isNotEmpty)
                Positioned(
                  top: 70,
                  left: 24,
                  right: 24,
                  child: Material(
                    color: const Color(0xFF1E1E1E),
                    borderRadius: BorderRadius.circular(16),
                    elevation: 8,
                    child: Container(
                      constraints: const BoxConstraints(maxHeight: 300),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: _isSearching
                          ? const Center(
                              child: Padding(
                                padding: EdgeInsets.all(16.0),
                                child: CircularProgressIndicator(
                                  color: Color(0xFF4CAF50),
                                ),
                              ),
                            )
                          : _searchResults.isEmpty
                              ? const Padding(
                                  padding: EdgeInsets.all(16.0),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.search_off,
                                        color: Color(0xFFB3B3B3),
                                        size: 48,
                                      ),
                                      SizedBox(height: 16),
                                      Text(
                                        'No users found',
                                        style: TextStyle(
                                          color: Color(0xFFB3B3B3),
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                      SizedBox(height: 8),
                                      Text(
                                        'Try a different search term',
                                        style: TextStyle(
                                          color: Color(0xFF808080),
                                          fontSize: 14,
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                    ],
                                  ),
                                )
                              : ListView.builder(
                                  shrinkWrap: true,
                                  physics: const BouncingScrollPhysics(),
                                  itemCount: _searchResults.length,
                                  itemBuilder: (context, index) {
                                    final user = _searchResults[index];
                                    return ListTile(
                                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                      leading: CircleAvatar(
                                        radius: 24,
                                        backgroundColor: Colors.grey[800],
                                        backgroundImage: user.profilePicture != null
                                            ? NetworkImage(user.profilePicture!)
                                            : null,
                                        child: user.profilePicture == null
                                            ? Text(
                                                (user.firstName ?? 'U')[0].toUpperCase(),
                                                style: const TextStyle(
                                                  fontSize: 18,
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              )
                                            : null,
                                      ),
                                      title: Text(
                                        user.username ?? 'No username',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      subtitle: Text(
                                        '${user.firstName ?? 'Unknown'} ${user.lastName ?? ''}',
                                        style: const TextStyle(
                                          color: Color(0xFFB3B3B3),
                                          fontSize: 14,
                                        ),
                                      ),
                                      trailing: ElevatedButton(
                                        onPressed: () => _sendFriendRequest(user.id),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: const Color(0xFF4CAF50),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(12),
                                          ),
                                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                        ),
                                        child: const Text(
                                          'Add Friend',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          _searchController.clear();
          _refreshIndicatorKey.currentState?.show();
        },
        backgroundColor: const Color(0xFF4CAF50),
        child: const Icon(Icons.refresh, color: Colors.white),
      ),
    );
  }

  Widget _buildFriendsTab() {
    if (_isLoadingFriends) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32.0),
          child: CircularProgressIndicator(
            color: Color(0xFF4CAF50),
          ),
        ),
      );
    }

    if (_friends.isEmpty) {
      return FadeTransition(
        opacity: _fadeAnimation,
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: Colors.grey[800],
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.people_outline,
                  color: Color(0xFF4CAF50),
                  size: 40,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'No friends yet',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              const Text(
                'Search for users to add them as friends',
                style: TextStyle(
                  color: Color(0xFFB3B3B3),
                  fontSize: 16,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () {
                  _searchController.text = '';
                  _searchController.selection = TextSelection.fromPosition(
                    TextPosition(offset: _searchController.text.length),
                  );
                  FocusScope.of(context).requestFocus(FocusNode());
                  Future.delayed(const Duration(milliseconds: 100), () {
                    FocusScope.of(context).requestFocus(FocusNode());
                  });
                },
                icon: const Icon(Icons.search),
                label: const Text('Find Friends'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4CAF50),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return FadeTransition(
      opacity: _fadeAnimation,
      child: ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 24.0),
        itemCount: _friends.length,
        separatorBuilder: (context, index) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final friend = _friends[index];
          return _buildFriendCard(friend);
        },
      ),
    );
  }

  Widget _buildRequestsTab() {
    if (_isLoadingRequests) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32.0),
          child: CircularProgressIndicator(
            color: Color(0xFF4CAF50),
          ),
        ),
      );
    }

    if (_friendRequests.isEmpty) {
      return FadeTransition(
        opacity: _fadeAnimation,
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: Colors.grey[800],
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.person_add_disabled,
                  color: Color(0xFFB3B3B3),
                  size: 40,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'No friend requests',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              const Text(
                'When someone sends you a friend request, it will appear here',
                style: TextStyle(
                  color: Color(0xFFB3B3B3),
                  fontSize: 16,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return FadeTransition(
      opacity: _fadeAnimation,
      child: ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 24.0),
        itemCount: _friendRequests.length,
        separatorBuilder: (context, index) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final request = _friendRequests[index];
          final sender = request['sender'] as UserModel;
          return _buildRequestCard(sender, request['request_id']);
        },
      ),
    );
  }

  Widget _buildFriendCard(UserModel friend) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _viewFriendProfile(friend),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Hero(
                  tag: 'profile_${friend.id}',
                  child: CircleAvatar(
                    radius: 30,
                    backgroundColor: Colors.grey[800],
                    backgroundImage: friend.profilePicture != null
                        ? NetworkImage(friend.profilePicture!)
                        : null,
                    child: friend.profilePicture == null
                        ? Text(
                            (friend.firstName ?? 'U')[0].toUpperCase(),
                            style: const TextStyle(
                              fontSize: 24,
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          )
                        : null,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        friend.username ?? 'No username',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${friend.firstName ?? 'Unknown'} ${friend.lastName ?? ''}',
                        style: const TextStyle(
                          color: Color(0xFF4CAF50),
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(
                        Icons.chat_bubble_outline,
                        color: Color(0xFF4CAF50),
                      ),
                      onPressed: () => _createChat(friend.id),
                      tooltip: 'Message',
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.more_vert,
                        color: Colors.white,
                      ),
                      onPressed: () {
                        showModalBottomSheet(
                          context: context,
                          backgroundColor: const Color(0xFF1E1E1E),
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
                                    _viewFriendProfile(friend);
                                  },
                                ),
                                ListTile(
                                  leading: const Icon(Icons.chat_bubble_outline, color: Color(0xFF4CAF50)),
                                  title: const Text(
                                    'Message',
                                    style: TextStyle(color: Colors.white),
                                  ),
                                  onTap: () {
                                    Navigator.pop(context);
                                    _createChat(friend.id);
                                  },
                                ),
                                ListTile(
                                  leading: const Icon(Icons.person_remove, color: Colors.redAccent),
                                  title: const Text(
                                    'Remove Friend',
                                    style: TextStyle(color: Colors.white),
                                  ),
                                  onTap: () {
                                    Navigator.pop(context);
                                    _showRemoveFriendDialog(friend);
                                  },
                                ),
                              ],
                            ),
                          ),
                        );
                      },
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

  Widget _buildRequestCard(UserModel sender, String requestId) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 30,
                  backgroundColor: Colors.grey[800],
                  backgroundImage: sender.profilePicture != null
                      ? NetworkImage(sender.profilePicture!)
                      : null,
                  child: sender.profilePicture == null
                      ? Text(
                          (sender.firstName ?? 'U')[0].toUpperCase(),
                          style: const TextStyle(
                            fontSize: 24,
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        )
                      : null,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        sender.username ?? 'No username',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${sender.firstName ?? 'Unknown'} ${sender.lastName ?? ''}',
                        style: const TextStyle(
                          color: Color(0xFFB3B3B3),
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _buildAnimatedButton(
                    label: 'Accept',
                    icon: Icons.check,
                    color: const Color(0xFF4CAF50),
                    onPressed: () => _acceptFriendRequest(requestId),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildAnimatedButton(
                    label: 'Decline',
                    icon: Icons.close,
                    color: Colors.redAccent,
                    onPressed: () => _declineFriendRequest(requestId),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnimatedButton({
    required String label,
    IconData? icon,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Ink(
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, color: Colors.white, size: 18),
                  const SizedBox(width: 8),
                ],
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
