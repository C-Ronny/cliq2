import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
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
  bool _isVideoEnabled = true;
  bool _isAudioEnabled = true;
  bool _isFrontCamera = true;
  late final RealtimeChannel _videoRoomsChannel;
  late final RealtimeChannel _callInvitesChannel;

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
            if (mounted) {
              setState(() {
                _remoteUids.add(remoteUid);
              });
            }
            print('Remote user joined: $remoteUid');
          },
          onUserOffline: (connection, remoteUid, reason) {
            if (mounted) {
              setState(() {
                _remoteUids.remove(remoteUid);
              });
            }
            print('Remote user left: $remoteUid');
          },
          onError: (err, msg) {
            print('Agora Error: $err, Message: $msg');
            if (mounted) {
              setState(() {
                _errorMessage = 'Agora Error: $msg';
              });
            }
          },
        ),
      );

      await _engine!.enableVideo();
      await _engine!.startPreview();
    } catch (e) {
      print('Agora initialization error: $e');
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to initialize video call: $e';
        });
      }
    }
  }

  void _setupRealtimeSubscriptions() {
    final currentUser = _authService.supabase.auth.currentUser;
    if (currentUser == null) {
      print('No current user, skipping real-time subscriptions');
      return;
    }

    print('Setting up real-time subscription for user: ${currentUser.id}');

    _callInvitesChannel = _authService.supabase
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
        .subscribe();

    _videoRoomsChannel = _authService.supabase
        .channel('video_rooms')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'video_rooms',
          callback: (payload) {
            print('Video rooms changed: $payload');
            _fetchActiveCalls();
          },
        )
        .subscribe();
  }

  Future<void> _fetchActiveCalls() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final currentUser = await _authService.getCurrentUser();
      if (currentUser == null) throw Exception('User not authenticated');

      final friends = await _authService.getFriends();
      final friendIds = friends.map((friend) => friend.id).toList();
      friendIds.add(currentUser.id);

      final response = await _authService.supabase
          .from('video_rooms')
          .select('*, creator_id(id, username, first_name, last_name)')
          .or(
            'creator_id.in.(${friendIds.join(',')}),participant_ids.cs.{${currentUser.id}}',
          );

      print('Fetched active calls: $response');
      if (mounted) {
        setState(() {
          _activeCalls = response;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString().replaceFirst('Exception: ', '');
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _fetchCallInvites() async {
    try {
      final invites = await _authService.getCallInvites();
      print('Fetched call invites: $invites');
      if (mounted) {
        setState(() {
          _callInvites = invites;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  Future<void> _acceptInvite(String inviteId, String roomId) async {
    try {
      final currentUser = await _authService.getCurrentUser();
      if (currentUser == null) throw Exception('User not authenticated');

      await _authService.supabase
          .from('call_invites')
          .update({'status': 'accepted'})
          .eq('id', inviteId);

      await _authService.joinVideoRoom(roomId, currentUser.id);

      final roomData = await _authService.supabase
          .from('video_rooms')
          .select()
          .eq('room_id', roomId)
          .single();

      if (mounted) {
        setState(() {
          _inCall = true;
          _currentRoom = roomData;
        });
        widget.updateCallState(_inCall, _showFriendOverlay);
      }

      await _engine!.joinChannel(
        token: '',
        channelId: roomId,
        uid: 0,
        options: const ChannelMediaOptions(
          clientRoleType: ClientRoleType.clientRoleBroadcaster,
          channelProfile: ChannelProfileType.channelProfileCommunication,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to accept invite: $e')),
        );
      }
    }
  }

  Future<void> _declineInvite(String inviteId) async {
    try {
      await _authService.supabase
          .from('call_invites')
          .update({'status': 'declined'})
          .eq('id', inviteId);

      if (mounted) {
        await _fetchCallInvites();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to decline invite: $e')),
        );
      }
    }
  }

  Future<void> _fetchFriendsForInvite() async {
    if (!mounted) return;
    setState(() {
      _isLoadingFriends = true;
    });

    try {
      final friends = await _authService.getFriends();
      final currentParticipants = _currentRoom != null
          ? List<String>.from(_currentRoom!['participant_ids'] as List)
          : <String>[];

      final availableFriends = friends
          .where((friend) => !currentParticipants.contains(friend.id))
          .toList();

      if (mounted) {
        setState(() {
          _friends = availableFriends;
          _isLoadingFriends = false;
        });
      }

      if (mounted) {
        await showModalBottomSheet(
          context: context,
          builder: (context) => _buildFriendOverlay(),
        );
        setState(() {
          _showFriendOverlay = false;
        });
        widget.updateCallState(_inCall, _showFriendOverlay);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingFriends = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to fetch friends: $e')),
        );
      }
    }
  }

  Future<void> _endCall() async {
    try {
      final currentUser = await _authService.getCurrentUser();
      if (currentUser == null || _currentRoom == null) return;

      final userId = currentUser.id;
      final roomId = _currentRoom!['room_id'];
      final creatorId = _currentRoom!['creator_id']['id'];

      await _engine!.leaveChannel();
      if (mounted) {
        setState(() {
          _remoteUids.clear();
        });
      }

      if (userId == creatorId) {
        await _authService.supabase.from('video_rooms').delete().eq('room_id', roomId);
      } else {
        final participantIds = List<String>.from(_currentRoom!['participant_ids']);
        participantIds.remove(userId);
        await _authService.supabase
            .from('video_rooms')
            .update({'participant_ids': participantIds})
            .eq('room_id', roomId);
      }

      if (mounted) {
        setState(() {
          _inCall = false;
          _currentRoom = null;
          _isVideoEnabled = true;
          _isAudioEnabled = true;
          _isFrontCamera = true;
        });
        widget.updateCallState(_inCall, _showFriendOverlay);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to end call: $e')),
        );
      }
    }
  }

  Widget _buildFriendOverlay() {
    return Container(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Invite Friends to Call',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          _isLoadingFriends
              ? const Center(child: CircularProgressIndicator(color: Color(0xFF4CAF50)))
              : _friends.isEmpty
                  ? const Center(
                      child: Text(
                        'No friends available to invite.',
                        style: TextStyle(color: Colors.white),
                      ),
                    )
                  : Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: _friends.length,
                        itemBuilder: (context, index) {
                          final friend = _friends[index];
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: Colors.grey[700],
                              child: Text(
                                friend.username?.substring(0, 1).toUpperCase() ?? 'U',
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                            title: Text(
                              friend.username ?? 'Unknown',
                              style: const TextStyle(color: Colors.white),
                            ),
                            trailing: ElevatedButton(
                              onPressed: () async {
                                try {
                                  await _authService.sendCallInvite(
                                    friend.id,
                                    _currentRoom!['room_id'],
                                  );
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('Invite sent successfully!')),
                                    );
                                  }
                                  Navigator.pop(context);
                                } catch (e) {
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('Failed to send invite: $e')),
                                    );
                                  }
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF4CAF50),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              child: const Text('Invite'),
                            ),
                          );
                        },
                      ),
                    ),
        ],
      ),
    );
  }

  Future<void> _startCall() async {
    try {
      final name = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: Colors.grey[800],
          title: const Text('Create New Call', style: TextStyle(color: Colors.white)),
          content: TextField(
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Call Name',
              hintStyle: TextStyle(color: Colors.grey[400]),
              enabledBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: Colors.white),
              ),
              focusedBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: Color(0xFF4CAF50)),
              ),
            ),
            onSubmitted: (value) => Navigator.pop(context, value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: Colors.white)),
            ),
            TextButton(
              onPressed: () {
                final controller = TextEditingController.fromValue(
                  TextEditingValue(text: (context.findAncestorWidgetOfExactType<AlertDialog>()?.content as TextField?)?.controller?.text ?? ''),
                );
                print('Dialog input: ${controller.text}');
                Navigator.pop(context, controller.text.isNotEmpty ? controller.text : null);
              },
              child: const Text('Create', style: TextStyle(color: Color(0xFF4CAF50))),
            ),
          ],
        ),
      );

      print('Dialog returned name: $name');
      if (name == null || name.trim().isEmpty) {
        print('No valid name provided');
        return;
      }

      final room = await _authService.createVideoRoom(name: name);
      print('Created room successfully: $room');

      final userId = (await _authService.getCurrentUser())!.id;
      await _authService.joinVideoRoom(room['room_id'], userId);

      if (mounted) {
        setState(() {
          _inCall = true;
          _currentRoom = room;
        });
        widget.updateCallState(_inCall, _showFriendOverlay);
      }

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
      print('Failed to start call: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start call: $e')),
        );
      }
    }
  }

  Widget _buildCallListView() {
    return RefreshIndicator(
      onRefresh: () async {
        if (mounted) {
          await _fetchActiveCalls();
          await _fetchCallInvites();
        }
      },
      child: Column(
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
                            final creatorData = call['creator_id'] as Map<String, dynamic>?;
                            final creator = creatorData != null
                                ? UserModel.fromJson(creatorData)
                                : UserModel(id: 'unknown', username: 'Unknown', firstName: 'Unknown');
                            final participantCount = (call['participant_ids'] as List?)?.length ?? 0;
                            final isLocked = call['locked'] as bool? ?? false;
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
                                  call['name']?.toString() ?? 'Unknown Call',
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
                                          if (mounted) {
                                            setState(() {
                                              _inCall = true;
                                              _currentRoom = call;
                                            });
                                            widget.updateCallState(_inCall, _showFriendOverlay);
                                          }
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
                                          if (mounted) {
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              SnackBar(content: Text('Failed to join call: $e')),
                                            );
                                          }
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
      ),
    );
  }

  Widget _buildVideoCallInterface() {
    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              if (_engine != null && _errorMessage == null)
                AgoraVideoView(
                  controller: VideoViewController(
                    rtcEngine: _engine!,
                    canvas: const VideoCanvas(uid: 0), // Local video
                  ),
                )
              else
                Center(
                  child: Text(
                    _errorMessage ?? 'Initializing video...',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              if (_remoteUids.isNotEmpty && _currentRoom != null && _errorMessage == null)
                ..._remoteUids.map((remoteUid) {
                  return Positioned.fill(
                    child: AgoraVideoView(
                      controller: VideoViewController(
                        rtcEngine: _engine!,
                        canvas: VideoCanvas(uid: remoteUid), // Remote video
                      ),
                    ),
                  );
                }).toList(),
              if (_remoteUids.isNotEmpty && _currentRoom != null && _errorMessage == null)
                ..._remoteUids.map((remoteUid) {
                  final participantId = _getParticipantIdFromUid(remoteUid);
                  final participantName = _getParticipantName(participantId);
                  return Positioned(
                    top: 10,
                    right: 10,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      color: Colors.black54,
                      child: Text(
                        participantName ?? 'Unknown',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  );
                }).toList(),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: Icon(
                      _isVideoEnabled ? Icons.videocam : Icons.videocam_off,
                      color: Colors.white,
                    ),
                    onPressed: () {
                      if (mounted) {
                        setState(() {
                          _isVideoEnabled = !_isVideoEnabled;
                        });
                        if (_isVideoEnabled) {
                          _engine!.enableVideo();
                        } else {
                          _engine!.disableVideo();
                        }
                      }
                    },
                  ),
                  IconButton(
                    icon: Icon(
                      _isAudioEnabled ? Icons.mic : Icons.mic_off,
                      color: Colors.white,
                    ),
                    onPressed: () {
                      if (mounted) {
                        setState(() {
                          _isAudioEnabled = !_isAudioEnabled;
                        });
                        _engine!.muteLocalAudioStream(!_isAudioEnabled);
                      }
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.flip_camera_android, color: Colors.white),
                    onPressed: () {
                      if (mounted) {
                        setState(() {
                          _isFrontCamera = !_isFrontCamera;
                        });
                        _engine!.switchCamera();
                      }
                    },
                  ),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton(
                    onPressed: () {
                      if (mounted) {
                        setState(() {
                          _showFriendOverlay = true;
                        });
                        widget.updateCallState(_inCall, _showFriendOverlay);
                        _fetchFriendsForInvite();
                      }
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
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _inCall ? _buildVideoCallInterface() : _buildCallListView(),
    );
  }

  @override
  void dispose() {
    _engine?.leaveChannel();
    _engine?.release();
    _callInvitesChannel.unsubscribe();
    _videoRoomsChannel.unsubscribe();
    super.dispose();
  }

  String? _getParticipantIdFromUid(int uid) {
    return _currentRoom?['participant_ids']?.firstWhere(
      (id) => _remoteUids.contains(uid), // Simplified; improve with actual UID mapping
      orElse: () => null,
    );
  }

  String? _getParticipantName(String? participantId) {
    if (participantId == null) return null;
    final user = _friends.firstWhere(
      (friend) => friend.id == participantId,
      orElse: () => UserModel(id: participantId, username: 'Unknown'),
    );
    return user.username;
  }
}