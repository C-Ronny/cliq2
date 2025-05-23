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
  bool _isCreator = false;
  final Map<int, String> _uidToUserIdMap = {};
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

  Future<String> _showNameDialog(BuildContext context) async {
    final TextEditingController controller = TextEditingController();
    String roomName = '';

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Enter Room Name'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'Room Name'),
          onChanged: (value) {
            roomName = value.trim();
          },
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
            },
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (roomName.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Room name cannot be empty')),
                );
                return;
              }
              Navigator.pop(context, roomName);
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );

    // If the dialog is dismissed (e.g., by pressing Cancel), return a default name or handle it
    return roomName.isNotEmpty ? roomName : 'Default Room';
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

      await _engine!.enableVideo();
      await _engine!.enableLocalVideo(true); // Ensure local video is enabled by default
      await _engine!.setVideoEncoderConfiguration(const VideoEncoderConfiguration(
        dimensions: VideoDimensions(width: 640, height: 360),
        frameRate: 15,
        bitrate: 600,
      ));
      await _engine!.startPreview();
      print('Local video preview started');

      _engine!.registerEventHandler(
        RtcEngineEventHandler(
          onJoinChannelSuccess: (connection, elapsed) async {
            print('Local user joined channel: ${connection.localUid}');
            final userId = (await _authService.getCurrentUser())?.id;
            if (userId != null && _currentRoom != null && connection.localUid != null) {
              _uidToUserIdMap[connection.localUid!] = userId;
            }
          },
          onUserJoined: (connection, remoteUid, elapsed) {
            print('Remote user joined: $remoteUid');
            if (mounted) {
              setState(() {
                _remoteUids.add(remoteUid);
                final participantIds = _currentRoom?['participant_ids'] as List<String>? ?? [];
                final availableIds = participantIds.where((id) => !_uidToUserIdMap.values.contains(id)).toList();
                if (availableIds.isNotEmpty) {
                  _uidToUserIdMap[remoteUid] = availableIds.first;
                }
              });
            }
          },
          onUserOffline: (connection, remoteUid, reason) {
            if (mounted) {
              setState(() {
                _remoteUids.remove(remoteUid);
                _uidToUserIdMap.remove(remoteUid);
              });
            }
            print('Remote user left: $remoteUid, reason: $reason');
          },
          onError: (err, msg) {
            print('Agora Error: $err, Message: $msg');
            if (mounted) {
              setState(() {
                _errorMessage = 'Agora Error: $msg';
              });
            }
          },
          onFirstRemoteVideoFrame: (connection, remoteUid, width, height, elapsed) {
            print('First remote video frame received from UID: $remoteUid, width: $width, height: $height');
            if (mounted) {
              setState(() {});
            }
          },
          onLocalVideoStateChanged: (source, state, error) {
            print('Local video state changed: $state, error: $error');
          },
          onRemoteVideoStateChanged: (connection, remoteUid, state, reason, elapsed) {
            print('Remote video state changed for UID: $remoteUid, state: $state, reason: $reason');
          },
          onUserEnableVideo: (connection, remoteUid, enabled) {
            print('Remote user $remoteUid video enabled: $enabled');
            if (mounted) {
              setState(() {
                if (enabled && !_remoteUids.contains(remoteUid)) {
                  _remoteUids.add(remoteUid);
                } else if (!enabled) {
                  _remoteUids.remove(remoteUid);
                }
              });
            }
          },
        ),
      );
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
          event: PostgresChangeEvent.all, // Listen for INSERT, UPDATE, DELETE
          schema: 'public',
          table: 'call_invites',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'invited_user_id',
            value: currentUser.id,
          ),
          callback: (payload) {
            print('Call invite changed: $payload');
            _fetchCallInvites(); // Refresh the invites list on any change
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

      final response = await _authService.supabase
          .from('video_rooms')
          .select('*, creator_id(id, username, first_name, last_name)')
          .or(
            'participant_ids.cs.{${currentUser.id}}', // Only fetch rooms where the user is a participant
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Accepting invite...')),
      );
      final currentUser = await _authService.getCurrentUser();
      if (currentUser == null) throw Exception('User not authenticated');

      final invite = await _authService.supabase
          .from('call_invites')
          .select('room_id')
          .eq('id', inviteId)
          .eq('invited_user_id', currentUser.id)
          .maybeSingle();
      if (invite == null || invite['room_id'] == null) {
        throw Exception('Invalid invite or room ID');
      }
      final validRoomId = invite['room_id'].toString();

      await _authService.acceptCallInvite(inviteId, validRoomId);

      final roomData = await _authService.supabase
          .from('video_rooms')
          .select()
          .eq('room_id', validRoomId)
          .single();

      setState(() {
        _inCall = true;
        _currentRoom = roomData;
        _isCreator = roomData['creator_id'] == currentUser.id;
      });
      widget.updateCallState(_inCall, _showFriendOverlay);

      const fixedChannelId = '0c610c2a-c710-44c4-83ae-469897755f90'; // Fixed channel ID for Agora
      print('Joining Agora channel with channelId: $fixedChannelId');
      await _engine!.joinChannel(
        token: '007eJxTYChfkmar+Ldo6fewvy80HsXE6988Hz7xPsdin7nlf5J/tQcrMJgbWZgYm1iam6WkJZukGFhamiWZWRgZmCcnGZqappkbsvpJZjQEMjLoXr7FwsgAgSC+CoNBspmhQbJRom6yuaGBrolJsomuhXFiqq6JmaWFpbk5ULelAQMDAEAyJ1U=',
        channelId: fixedChannelId,
        uid: 0,
        options: const ChannelMediaOptions(
          clientRoleType: ClientRoleType.clientRoleBroadcaster,
          channelProfile: ChannelProfileType.channelProfileCommunication,
          autoSubscribeVideo: true,
          autoSubscribeAudio: true,
          publishCameraTrack: true,
          publishMicrophoneTrack: true,
        ),
      );

      if (mounted) {
        await _fetchCallInvites();
      }
    } catch (e) {
      print('Error in _acceptInvite: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to accept invite: ${e.toString().replaceAll('Exception: ', '')}'),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: 'Retry',
            textColor: Colors.white,
            onPressed: () => _acceptInvite(inviteId, roomId),
          ),
        ),
      );
    }
  }

  Future<void> _declineInvite(String inviteId) async {
    try {
      await _authService.supabase
          .from('call_invites')
          .update({'status': 'declined'})
          .eq('id', inviteId);

      if (mounted) {
        await _fetchCallInvites(); // Refresh the invites list after decline
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
          SnackBar(
            content: Text('Failed to fetch friends: ${e.toString().replaceAll('Exception: ', '')}'),
            backgroundColor: const Color(0xFF4CAF50),
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: 'Retry',
              textColor: Colors.white,
              onPressed: _fetchFriendsForInvite,
            ),
          ),
        );
      }
    }
  }

  Future<void> _startCall() async {
    try {
      final roomName = await _showNameDialog(context);
      if (roomName.isEmpty) return;

      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });

      final currentUser = await _authService.getCurrentUser();
      if (currentUser == null) throw Exception('User not authenticated');

      print('Creating video room with name: $roomName');
      final roomData = await _authService.createVideoRoom(name: roomName);
      if (roomData == null) throw Exception('Failed to create room');

      print('Created room successfully: $roomData');

      setState(() {
        _inCall = true;
        _currentRoom = roomData;
        _isCreator = true;
      });

      widget.updateCallState(_inCall, _showFriendOverlay);

      print('Joining room with userId: ${currentUser.id}');
      await _authService.joinVideoRoom(roomData['room_id'], currentUser.id);

      const fixedChannelId = '0c610c2a-c710-44c4-83ae-469897755f90';
      print('Joining Agora channel with channelId: $fixedChannelId');
      await _engine!.joinChannel(
        token: '007eJxTYChfkmar+Ldo6fewvy80HsXE6988Hz7xPsdin7nlf5J/tQcrMJgbWZgYm1iam6WkJZukGFhamiWZWRgZmCcnGZqappkbsvpJZjQEMjLoXr7FwsgAgSC+CoNBspmhQbJRom6yuaGBrolJsomuhXFiqq6JmaWFpbk5ULelAQMDAEAyJ1U=',
        channelId: fixedChannelId,
        uid: 0,
        options: const ChannelMediaOptions(
          clientRoleType: ClientRoleType.clientRoleBroadcaster,
          channelProfile: ChannelProfileType.channelProfileCommunication,
          autoSubscribeVideo: true,
          autoSubscribeAudio: true,
          publishCameraTrack: true,
          publishMicrophoneTrack: true,
        ),
      );

      print('Successfully joined Agora channel');
    } catch (e) {
      print('Error in _startCall: $e');
      if (mounted) {
        setState(() {
          _errorMessage = e.toString().replaceFirst('Exception: ', '');
          _inCall = false;
          _currentRoom = null;
          _isCreator = false;
        });
        widget.updateCallState(_inCall, _showFriendOverlay);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to start call: ${_errorMessage!}'),
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: 'Retry',
              textColor: Colors.white,
              onPressed: _startCall,
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _endCall() async {
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ending call...')),
      );
      final currentUser = await _authService.getCurrentUser();
      if (currentUser == null || _currentRoom == null) {
        throw Exception('User or room data unavailable');
      }

      final userId = currentUser.id;
      final roomId = _currentRoom!['room_id'];
      final creatorId = _currentRoom!['creator_id'];

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
      print('Error in _endCall: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to end call: ${e.toString().replaceAll('Exception: ', '')}'),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: 'Retry',
            textColor: Colors.white,
            onPressed: _endCall,
          ),
        ),
      );
    }
  }

  Widget _buildFriendOverlay() {
    return Container(
      padding: const EdgeInsets.all(16.0),
      color: const Color.fromARGB(255, 171, 171, 171),
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
                                      const SnackBar(content: Text('Invite sent!')),
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

  Future<void> _leaveCall() async {
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Leaving call...')),
      );
      final currentUser = await _authService.getCurrentUser();
      if (currentUser == null || _currentRoom == null) {
        throw Exception('User or room data unavailable');
      }

      final userId = currentUser.id;
      final roomId = _currentRoom!['room_id'];

      await _engine!.leaveChannel();
      if (mounted) {
        setState(() {
          _remoteUids.clear();
        });
      }

      await _authService.leaveVideoRoom(roomId, userId);

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
      print('Error in _leaveCall: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to leave call: ${e.toString().replaceAll('Exception: ', '')}'),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: 'Retry',
            textColor: Colors.white,
            onPressed: _leaveCall,
          ),
        ),
      );
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
                            if (invite['status'] != 'pending') return const SizedBox.shrink(); // Skip non-pending invites
                            final room = invite['room_id'];
                            if (room == null) {
                              return Card(
                                color: Colors.grey[800],
                                child: ListTile(
                                  leading: CircleAvatar(
                                    backgroundColor: Colors.grey[700],
                                    child: const Text(
                                      'U',
                                      style: TextStyle(color: Colors.white),
                                    ),
                                  ),
                                  title: const Text(
                                    'Unknown Call',
                                    style: TextStyle(color: Colors.white),
                                  ),
                                  subtitle: const Text(
                                    'Invite from Unknown',
                                    style: TextStyle(color: Color.fromARGB(255, 41, 41, 41)),
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
                                  style: TextStyle(color: Colors.white),
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
                                  style: TextStyle(color: Colors.white),
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
                                            _isCreator = call['creator_id'] == userId;
                                          });
                                          widget.updateCallState(_inCall, _showFriendOverlay);
                                        }
                                        const fixedChannelId = '0c610c2a-c710-44c4-83ae-469897755f90'; 
                                        await _engine!.joinChannel(
                                          token: '007eJxTYChfkmar+Ldo6fewvy80HsXE6988Hz7xPsdin7nlf5J/tQcrMJgbWZgYm1iam6WkJZukGFhamiWZWRgZmCcnGZqappkbsvpJZjQEMjLoXr7FwsgAgSC+CoNBspmhQbJRom6yuaGBrolJsomuhXFiqq6JmaWFpbk5ULelAQMDAEAyJ1U=',
                                          channelId: fixedChannelId,
                                          uid: 0,
                                          options: const ChannelMediaOptions(
                                            clientRoleType: ClientRoleType.clientRoleBroadcaster,
                                            channelProfile: ChannelProfileType.channelProfileCommunication,
                                            autoSubscribeVideo: true,
                                            autoSubscribeAudio: true,
                                            publishCameraTrack: true,
                                            publishMicrophoneTrack: true,
                                          ),
                                        );
                                        await _fetchCallInvites();
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
    final currentRoomParticipants = _currentRoom != null
        ? List<String>.from(_currentRoom!['participant_ids'] as List)
        : <String>[];

    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              // Local video
              if (_engine != null && _errorMessage == null)
                Container(
                  color: Colors.black,
                  child: Center(
                    child: AgoraVideoView(
                      controller: VideoViewController(
                        rtcEngine: _engine!,
                        canvas: const VideoCanvas(
                          uid: 0,
                          renderMode: RenderModeType.renderModeFit,
                        ),
                        useAndroidSurfaceView: true,
                      ),
                    ),
                  ),
                )
              else
                Center(
                  child: Text(
                    _errorMessage ?? 'Initializing video...',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              // Remote videos
              if (_remoteUids.isNotEmpty && _errorMessage == null)
                GridView.builder(
                  padding: const EdgeInsets.all(8.0),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    childAspectRatio: 1.0,
                  ),
                  itemCount: _remoteUids.length,
                  itemBuilder: (context, index) {
                    final remoteUid = _remoteUids[index];
                    final userId = _uidToUserIdMap[remoteUid];
                    if (userId != null && currentRoomParticipants.contains(userId)) {
                      return Container(
                        color: Colors.black,
                        child: Stack(
                          children: [
                            AgoraVideoView(
                              controller: VideoViewController(
                                rtcEngine: _engine!,
                                canvas: VideoCanvas(
                                  uid: remoteUid,
                                  renderMode: RenderModeType.renderModeFit,
                                ),
                                useAndroidSurfaceView: true,
                              ),
                            ),
                            Positioned(
                              top: 8,
                              left: 8,
                              child: Text(
                                'UID: $remoteUid',
                                style: const TextStyle(color: Colors.white, fontSize: 12),
                              ),
                            ),
                            // Display "No Video" label for remote users
                            const Positioned(
                                top: 24,
                                left: 8,
                                child: Text(
                                  'Remote User',
                                  style: TextStyle(color: Colors.white, fontSize: 12),
                                ),
                              ),
                          ],
                        ),
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
              Positioned(
                top: 16,
                left: 16,
                child: IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () async {
                    if (_isCreator) {
                      await _endCall();
                    } else {
                      await _leaveCall();
                    }
                    setState(() {
                      _inCall = false;
                    });
                    widget.updateCallState(_inCall, _showFriendOverlay);
                  },
                ),
              ),
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
                      setState(() {
                        _isVideoEnabled = !_isVideoEnabled;
                      });
                      if (_isVideoEnabled) {
                        _engine!.enableLocalVideo(true);
                        _engine!.enableVideo();
                        _engine!.startPreview();
                      } else {
                        _engine!.enableLocalVideo(false);
                        _engine!.disableVideo();
                        _engine!.stopPreview();
                      }
                    },
                  ),
                  IconButton(
                    icon: Icon(
                      _isAudioEnabled ? Icons.mic : Icons.mic_off,
                      color: Colors.white,
                    ),
                    onPressed: () {
                      setState(() {
                        _isAudioEnabled = !_isAudioEnabled;
                      });
                      _engine!.muteLocalAudioStream(!_isAudioEnabled);
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.flip_camera_android, color: Colors.white),
                    onPressed: () {
                      setState(() {
                        _isFrontCamera = !_isFrontCamera;
                      });
                      _engine!.switchCamera();
                    },
                  ),
                ],
              ),
              Row(
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
                    onPressed: _isCreator ? _endCall : _leaveCall,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(_isCreator ? 'End Call' : 'Leave Call'),
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