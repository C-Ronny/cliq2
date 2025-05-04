import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../auth/auth_service.dart';
import '../../../models/user_model.dart';

class HomeScreen extends StatefulWidget {
  final Function(bool inCall, bool overlayActive) updateCallState;
  const HomeScreen({super.key, required this.updateCallState});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _authService = AuthService();
  List<Map<String, dynamic>> _activeCalls = [];
  List<Map<String, dynamic>> _callInvites = [];
  List<UserModel> _friends = [];
  bool _isLoading = true;
  bool _isLoadingFriends = false;
  String? _errorMessage;
  bool _inCall = false;
  bool _showFriendOverlay = false;
  Map<String, dynamic>? _currentRoom;
  RtcEngine? _engine;
  final List<int> _remoteUids = [];

  @override
  void initState() {
    super.initState();
    _fetchActiveCalls();
    _fetchCallInvites();
    _initializeAgora();
    _setupRealtimeSubscriptions();
    widget.updateCallState(_inCall, _showFriendOverlay);
  }

  Future<void> _initializeAgora() async {
    try {
      // Request camera and microphone permissions
      final cameraStatus = await Permission.camera.request();
      final micStatus = await Permission.microphone.request();

      if (cameraStatus != PermissionStatus.granted || micStatus != PermissionStatus.granted) {
        throw Exception('Camera or microphone permission denied');
      }

      print('Agora App ID: ${dotenv.env['AGORA_APP_ID']}');
      if (dotenv.env['AGORA_APP_ID'] == null || dotenv.env['AGORA_APP_ID']!.isEmpty) {
        throw Exception('Agora App ID is missing in .env file');
      }

      _engine = createAgoraRtcEngine();
      await _engine!.initialize(RtcEngineContext(
        appId: dotenv.env['AGORA_APP_ID']!,
        channelProfile: ChannelProfileType.channelProfileCommunication,
      ));

      _engine!.registerEventHandler(
        RtcEngineEventHandler(
          onJoinChannelSuccess: (connection, elapsed) {
            print('Local user joined channel: ${connection.localUid}');
          },
          onUserJoined: (connection, remoteUid, elapsed) {
            setState(() {
              _remoteUids.add(remoteUid);
            });
            print('Remote user joined: $remoteUid');
          },
          onUserOffline: (connection, remoteUid, reason) {
            setState(() {
              _remoteUids.remove(remoteUid);
            });
            print('Remote user left: $remoteUid');
          },
          onError: (err, msg) {
            print('Agora Error: $err, Message: $msg');
            setState(() {
              _errorMessage = 'Agora Error: $msg';
            });
          },
        ),
      );

      await _engine!.enableVideo();
      await _engine!.startPreview();
    } catch (e) {
      print('Agora initialization error: $e');
      setState(() {
        _errorMessage = 'Failed to initialize video call: $e';
      });
    }
  }

  void _setupRealtimeSubscriptions() {
    final currentUser = _authService.supabase.auth.currentUser;
    if (currentUser == null) {
      print('No current user, skipping real-time subscriptions');
      return;
    }

    print('Setting up real-time subscription for user: ${currentUser.id}');

    // Subscription for call invites
    _authService.supabase
        .channel('call_invites')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'call_invites',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'invited_user_id',
            value: currentUser.id,
          ),
          callback: (payload) {
            print('New call invite received: $payload');
            _fetchCallInvites();
          },
        )
        .subscribe((status, [error]) {
          if (status == 'SUBSCRIBED') {
            print('Successfully subscribed to call_invites channel');
          } else {
            print('Subscription status: $status, Error: $error');
          }
        });

    // Subscription for active calls
    _authService.supabase
        .channel('video_rooms')
        .onPostgresChanges(
          event: PostgresChangeEvent.all, // Listen for all changes (insert, update, delete)
          schema: 'public',
          table: 'video_rooms',
          callback: (payload) {
            print('Video rooms changed: $payload');
            _fetchActiveCalls();
          },
        )
        .subscribe((status, [error]) {
          if (status == 'SUBSCRIBED') {
            print('Successfully subscribed to video_rooms channel');
          } else {
            print('Subscription status: $status, Error: $error');
          }
        });
  }

  Future<void> _fetchActiveCalls() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final currentUser = await _authService.getCurrentUser();
      if (currentUser == null) throw Exception('User not authenticated');

      final friends = await _authService.getFriends();
      final friendIds = friends.map((friend) => friend.id).toList();

      final response = await _authService.supabase
          .from('video_rooms')
          .select('*, creator_id(username, first_name, last_name)')
          .inFilter('creator_id', friendIds);

      setState(() {
        _activeCalls = response;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
        _isLoading = false;
      });
    }
  }


  Future<void> _fetchFriendsForInvite() async {
    setState(() {
      _isLoadingFriends = true;
    });

    try {
      final friends = await _authService.getFriends();
      final participantIds = _currentRoom!['participant_ids'] as List<dynamic>;
      final inviteableFriends = friends.where((friend) => !participantIds.contains(friend.id)).toList();

      setState(() {
        _friends = inviteableFriends;
        _isLoadingFriends = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
        _isLoadingFriends = false;
      });
    }
  }

  Future<void> _startCall() async {
    final name = await _showCreateCallDialog(context);
    print('Dialog returned name: $name');
    if (name != null && name.isNotEmpty) {
      try {
        final room = await _authService.createVideoRoom(name: name);
        print('Created room successfully: $room');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Call created successfully!')),
        );

        setState(() {
          _inCall = true;
          _currentRoom = room;
          _showFriendOverlay = true;
        });
        widget.updateCallState(_inCall, _showFriendOverlay);

        await _fetchFriendsForInvite();

        await _engine!.joinChannel(
          token: '',
          channelId: room['room_id'].toString(),
          uid: 0,
          options: const ChannelMediaOptions(
            clientRoleType: ClientRoleType.clientRoleBroadcaster,
            channelProfile: ChannelProfileType.channelProfileCommunication,
          ),
        );
      } catch (e) {
        print('Error creating room: $e');
        setState(() {
          _errorMessage = e.toString().replaceFirst('Exception: ', '');
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to create call: $_errorMessage')),
        );
      }
    } else {
      print('No valid name provided');
    }
  }

  Future<void> _sendInvite(String friendId) async {
    try {
      await _authService.sendCallInvite(_currentRoom!['room_id'], friendId);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invite sent successfully!')),
      );
      setState(() {
        _friends = _friends.where((friend) => friend.id != friendId).toList();
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send invite: $_errorMessage')),
      );
    }
  }

  Future<void> _acceptInvite(String inviteId, String roomId) async {
    try {
      await _authService.acceptCallInvite(inviteId, roomId);
      final room = await _authService.supabase
          .from('video_rooms')
          .select()
          .eq('room_id', roomId)
          .single();

      setState(() {
        _inCall = true;
        _currentRoom = room;
        _callInvites = _callInvites.where((invite) => invite['id'] != inviteId).toList();
      });
      widget.updateCallState(_inCall, _showFriendOverlay);

      await _engine!.joinChannel(
        token: '',
        channelId: roomId,
        uid: 0,
        options: const ChannelMediaOptions(
          clientRoleType: ClientRoleType.clientRoleBroadcaster,
          channelProfile: ChannelProfileType.channelProfileCommunication,
        ),
      );

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Joined call successfully!')),
      );
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to join call: $_errorMessage')),
      );
    }
  }

  Future<void> _declineInvite(String inviteId) async {
    try {
      await _authService.declineCallInvite(inviteId);
      setState(() {
        _callInvites = _callInvites.where((invite) => invite['id'] != inviteId).toList();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invite declined')),
      );
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to decline invite: $_errorMessage')),
      );
    }
  }

  Future<void> _endCall() async {
    try {
      await _engine!.leaveChannel();
      await _authService.leaveVideoRoom(_currentRoom!['room_id'], (await _authService.getCurrentUser())!.id);
      setState(() {
        _inCall = false;
        _showFriendOverlay = false;
        _currentRoom = null;
        _remoteUids.clear();
      });
      widget.updateCallState(_inCall, _showFriendOverlay);
      _fetchActiveCalls();
      _fetchCallInvites();
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<String?> _showCreateCallDialog(BuildContext context) async {
    String? callName;
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create New Call'),
        content: TextField(
          decoration: const InputDecoration(labelText: 'Call Name'),
          onChanged: (value) => callName = value,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, callName),
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _engine?.leaveChannel();
    _engine?.release();
    _authService.supabase.channel('call_invites').unsubscribe();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: Stack(
        children: [
          SafeArea(
            child: _inCall ? _buildVideoCallInterface() : _buildCallListView(),
          ),
          if (_showFriendOverlay) _buildFriendOverlay(),
        ],
      ),
    );
  }

  Future<void> _fetchCallInvites() async {
    try {
      final invites = await _authService.getCallInvites();
      setState(() {
        _callInvites = invites;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

Widget _buildCallListView() {
  return Column(
    children: [
      Expanded(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator(color: Color(0xFF4CAF50)))
            : (_activeCalls.isEmpty && _callInvites.isEmpty)
                ? const Center(
                    child: Text(
                      'No active calls or invites.',
                      style: TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16.0),
                    itemCount: _callInvites.length + _activeCalls.length,
                    itemBuilder: (context, index) {
                      if (index < _callInvites.length) {
                        final invite = _callInvites[index];
                        final room = invite['room_id'];
                        if (room == null) {
                          return Card(
                            color: Colors.grey[800],
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: Colors.grey[700],
                                child: Text(
                                  'U',
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ),
                              title: Text(
                                'Unknown Call',
                                style: const TextStyle(color: Colors.white),
                              ),
                              subtitle: Text(
                                'Invite from Unknown',
                                style: TextStyle(color: Colors.grey[400]),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.check, color: Colors.green),
                                    onPressed: () => _acceptInvite(invite['id'], invite['room_id'].toString()),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.close, color: Colors.red),
                                    onPressed: () => _declineInvite(invite['id']),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }

                        final creator = room['creator_id'] != null && room['creator_id'] is Map
                            ? room['creator_id']
                            : {'username': 'U', 'first_name': 'Unknown'};

                        return Card(
                          color: Colors.grey[800],
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: Colors.grey[700],
                              child: Text(
                                (creator['username'] as String?)?.substring(0, 1).toUpperCase() ?? 'U',
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                            title: Text(
                              room['name']?.toString() ?? 'Unknown Call',
                              style: const TextStyle(color: Colors.white),
                            ),
                            subtitle: Text(
                              'Invite from ${creator['first_name'] ?? 'Unknown'}',
                              style: TextStyle(color: Colors.grey[400]),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.check, color: Colors.green),
                                  onPressed: () => _acceptInvite(invite['id'], invite['room_id'].toString()),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.close, color: Colors.red),
                                  onPressed: () => _declineInvite(invite['id']),
                                ),
                              ],
                            ),
                          ),
                        );
                      } else {
                        final call = _activeCalls[index - _callInvites.length];
                        final creator = UserModel.fromJson(call['creator_id']);
                        final participantCount = call['participant_ids'].length;
                        final isLocked = call['locked'];
                        final isJoinable = !isLocked && participantCount < 4;

                        return Card(
                          color: Colors.grey[800],
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: Colors.grey[700],
                              child: Text(
                                creator.username?.substring(0, 1).toUpperCase() ?? 'U',
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                            title: Text(
                              call['name'],
                              style: const TextStyle(color: Colors.white),
                            ),
                            subtitle: Text(
                              'by ${creator.firstName ?? 'Unknown'} | ${isLocked ? 'Locked' : 'Unlocked'}, $participantCount/4',
                              style: TextStyle(color: Colors.grey[400]),
                            ),
                            trailing: Icon(
                              isJoinable ? Icons.check_circle : Icons.cancel,
                              color: isJoinable ? Colors.green : Colors.red,
                            ),
                            onTap: isJoinable
                                ? () async {
                                    try {
                                      final userId = (await _authService.getCurrentUser())!.id;
                                      await _authService.joinVideoRoom(call['room_id'], userId);
                                      setState(() {
                                        _inCall = true;
                                        _currentRoom = call;
                                      });
                                      widget.updateCallState(_inCall, _showFriendOverlay);
                                      await _engine!.joinChannel(
                                        token: '',
                                        channelId: call['room_id'].toString(),
                                        uid: 0,
                                        options: const ChannelMediaOptions(
                                          clientRoleType: ClientRoleType.clientRoleBroadcaster,
                                          channelProfile: ChannelProfileType.channelProfileCommunication,
                                        ),
                                      );
                                    } catch (e) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('Failed to join call: $e')),
                                      );
                                    }
                                  }
                                : null,
                          ),
                        );
                      }
                    },
                  ),
      ),
      Padding(
        padding: const EdgeInsets.all(16.0),
        child: ElevatedButton(
          onPressed: _startCall,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF4CAF50),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: const Text('Start Call'),
        ),
      ),
      if (_errorMessage != null)
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Text(
            _errorMessage!,
            style: const TextStyle(color: Colors.redAccent, fontSize: 14),
          ),
        ),
    ],
  );
}


  Widget _buildVideoCallInterface() {
  return Column(
    children: [
      Expanded(
        child: Stack(
          children: [
            _engine != null && _errorMessage == null
                ? AgoraVideoView(
                    controller: VideoViewController(
                      rtcEngine: _engine!,
                      canvas: const VideoCanvas(uid: 0),
                    ),
                  )
                : Center(
                    child: Text(
                      _errorMessage ?? 'Initializing video...',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
            if (_remoteUids.isNotEmpty && _errorMessage == null)
              GridView.builder(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                ),
                itemCount: _remoteUids.length,
                itemBuilder: (context, index) {
                  return AgoraVideoView(
                    controller: VideoViewController(
                      rtcEngine: _engine!,
                      canvas: VideoCanvas(uid: _remoteUids[index]),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _showFriendOverlay = true;
                });
                widget.updateCallState(_inCall, _showFriendOverlay);
                _fetchFriendsForInvite();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4CAF50),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Invite Friends'),
            ),
            const SizedBox(width: 16),
            ElevatedButton(
              onPressed: _endCall,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('End Call'),
            ),
          ],
        ),
      ),
    ],
  );
}

  Widget _buildFriendOverlay() {
    return Container(
      color: Colors.black.withOpacity(0.9),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                'Invite Friends to ${_currentRoom!['name']}',
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            Expanded(
              child: _isLoadingFriends
                  ? const Center(child: CircularProgressIndicator(color: Color(0xFF4CAF50)))
                  : _friends.isEmpty
                      ? const Center(
                          child: Text(
                            'No friends available to invite.',
                            style: TextStyle(color: Colors.white, fontSize: 16),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(16.0),
                          itemCount: _friends.length,
                          itemBuilder: (context, index) {
                            final friend = _friends[index];
                            return Card(
                              color: Colors.grey[800],
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: Colors.grey[700],
                                  child: Text(
                                    friend.username?.substring(0, 1).toUpperCase() ?? 'U',
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                ),
                                title: Text(
                                  friend.username ?? 'No username',
                                  style: const TextStyle(color: Colors.white),
                                ),
                                subtitle: Text(
                                  '${friend.firstName ?? 'Unknown'} ${friend.lastName ?? ''}',
                                  style: TextStyle(color: Colors.grey[400]),
                                ),
                                trailing: ElevatedButton(
                                  onPressed: () => _sendInvite(friend.id),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF4CAF50),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                  child: const Text('Invite'),
                                ),
                              ),
                            );
                          },
                        ),
            ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: ElevatedButton(
                onPressed: () {
                  setState(() {
                    _showFriendOverlay = false;
                  });
                  widget.updateCallState(_inCall, _showFriendOverlay);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.grey[600],
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Done'),
              ),
            ),
            if (_errorMessage != null)
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(
                  _errorMessage!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 14),
                ),
              ),
          ],
        ),
      ),
    );
  }
}