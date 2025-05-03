import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../auth/auth_service.dart';
import '../../../models/user_model.dart';
import 'friend_profile_screen.dart';
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
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
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
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
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
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
        _isSearching = false;
      });
      print('Search error: $e');
    }
  }

  void _onSearchChanged(String query) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 100), () {
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
          content: Text('Friend request sent!'),
          backgroundColor: Color(0xFF4CAF50),
          duration: Duration(seconds: 3),
        ),
      );
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _acceptFriendRequest(String requestId) async {
    try {
      await _authService.acceptFriendRequest(requestId);
      await _fetchData();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Friend request accepted!'),
          backgroundColor: Color(0xFF4CAF50),
          duration: Duration(seconds: 3),
        ),
      );
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _declineFriendRequest(String requestId) async {
    try {
      await _authService.declineFriendRequest(requestId);
      await _fetchData();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Friend request declined.'),
          backgroundColor: Colors.redAccent,
          duration: Duration(seconds: 3),
        ),
      );
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _removeFriend(String friendId) async {
    try {
      await _authService.removeFriend(friendId);
      await _fetchData();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Friend removed.'),
          backgroundColor: Colors.redAccent,
          duration: Duration(seconds: 3),
        ),
      );
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _fetchData,
      color: const Color(0xFF4CAF50),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Stack(
          children: [
            Column(
              children: [
                const SizedBox(height: 40),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0),
                  child: TextField(
                    controller: _searchController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Search users...',
                      hintStyle: const TextStyle(color: Color(0xFFB3B3B3)),
                      filled: true,
                      fillColor: Colors.grey[800],
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      prefixIcon: const Icon(
                        Icons.search,
                        color: Color(0xFFB3B3B3),
                      ),
                    ),
                    onChanged: _onSearchChanged,
                  ),
                ),
                const SizedBox(height: 16),
                DefaultTabController(
                  length: 2,
                  child: Column(
                    children: [
                      TabBar(
                        labelColor: Colors.white,
                        unselectedLabelColor: const Color(0xFFB3B3B3),
                        indicator: const BoxDecoration(),
                        dividerColor: Colors.transparent,
                        labelPadding: const EdgeInsets.symmetric(horizontal: 16.0),
                        tabs: [
                          Tab(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  _friends.length.toString(),
                                  style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const Text(
                                  'Friends',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                          Tab(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  _friendRequests.length.toString(),
                                  style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const Text(
                                  'Requests',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      SizedBox(
                        height: MediaQuery.of(context).size.height - 300,
                        child: TabBarView(
                          children: [
                            _isLoadingFriends
                                ? const Center(
                                    child: CircularProgressIndicator(
                                      color: Color(0xFF4CAF50),
                                    ),
                                  )
                                : _friends.isEmpty
                                    ? const Center(
                                        child: Text(
                                          'No friends yet.',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 16,
                                          ),
                                        ),
                                      )
                                    : ListView.builder(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 24.0, vertical: 16.0),
                                        itemCount: _friends.length,
                                        itemBuilder: (context, index) {
                                          final friend = _friends[index];
                                          return Padding(
                                            padding:
                                                const EdgeInsets.symmetric(vertical: 4.0),
                                            child: _buildUserCard(
                                              user: friend,
                                              onTap: () {
                                                context.push(
                                                  '/main/friend-profile',
                                                  extra: friend,
                                                );
                                              },
                                              actionButton: _buildAnimatedButton(
                                                label: 'Remove',
                                                color: Colors.redAccent,
                                                onPressed: () => _removeFriend(friend.id),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                            _isLoadingRequests
                                ? const Center(
                                    child: CircularProgressIndicator(
                                      color: Color(0xFF4CAF50),
                                    ),
                                  )
                                : _friendRequests.isEmpty
                                    ? const Center(
                                        child: Text(
                                          'No friend requests.',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 16,
                                          ),
                                        ),
                                      )
                                    : ListView.builder(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 24.0, vertical: 16.0),
                                        itemCount: _friendRequests.length,
                                        itemBuilder: (context, index) {
                                          final request = _friendRequests[index];
                                          final sender = request['sender'] as UserModel;
                                          return Padding(
                                            padding:
                                                const EdgeInsets.symmetric(vertical: 4.0),
                                            child: _buildUserCard(
                                              user: sender,
                                              actionButton: Row(
                                                children: [
                                                  _buildAnimatedButton(
                                                    label: 'Accept',
                                                    color: const Color(0xFF4CAF50),
                                                    onPressed: () => _acceptFriendRequest(
                                                        request['request_id']),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  _buildAnimatedButton(
                                                    label: 'Decline',
                                                    color: Colors.redAccent,
                                                    onPressed: () => _declineFriendRequest(
                                                        request['request_id']),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 14,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
                const SizedBox(height: 80),
              ],
            ),
            if (_isSearching || _searchResults.isNotEmpty)
              Positioned(
                top: 90,
                left: 24,
                right: 24,
                child: Material(
                  color: Colors.grey[900],
                  borderRadius: BorderRadius.circular(12),
                  elevation: 4,
                  child: Container(
                    constraints: const BoxConstraints(maxHeight: 300),
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
                                child: Text(
                                  'No users found.',
                                  style: TextStyle(
                                    color: Color(0xFFB3B3B3),
                                    fontSize: 16,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              )
                            : ListView.builder(
                                shrinkWrap: true,
                                physics: const AlwaysScrollableScrollPhysics(),
                                itemCount: _searchResults.length,
                                itemBuilder: (context, index) {
                                  final user = _searchResults[index];
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16.0, vertical: 8.0),
                                    child: Row(
                                      children: [
                                        CircleAvatar(
                                          radius: 20,
                                          backgroundImage: user.profilePicture != null
                                              ? NetworkImage(user.profilePicture!)
                                              : null,
                                          child: user.profilePicture == null
                                              ? Text(
                                                  (user.firstName ?? 'U')[0].toUpperCase(),
                                                  style: const TextStyle(
                                                    fontSize: 16,
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                )
                                              : null,
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                user.username ?? 'No username',
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                '${user.firstName ?? 'Unknown'} ${user.lastName ?? ''}',
                                                style: const TextStyle(
                                                  color: Color(0xFFB3B3B3),
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        _buildAnimatedButton(
                                          label: 'Send Request',
                                          color: const Color(0xFF4CAF50),
                                          onPressed: () => _sendFriendRequest(user.id),
                                        ),
                                      ],
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
    );
  }

  Widget _buildUserCard({
    required UserModel user,
    Widget? actionButton,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.grey[800],
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundImage: user.profilePicture != null
                  ? NetworkImage(user.profilePicture!)
                  : null,
              child: user.profilePicture == null
                  ? Text(
                      (user.firstName ?? 'U')[0].toUpperCase(),
                      style: const TextStyle(
                        fontSize: 20,
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user.username ?? 'No username',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${user.firstName ?? 'Unknown'} ${user.lastName ?? ''}',
                    style: const TextStyle(
                      color: Color(0xFFB3B3B3),
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
            if (actionButton != null) actionButton,
          ],
        ),
      ),
    );
  }

  Widget _buildAnimatedButton({
    required String label,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return GestureDetector(
      onTap: onPressed,
      child: AnimatedScale(
        scale: 1.0,
        duration: const Duration(milliseconds: 150),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}