import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import '../../auth/auth_service.dart'; // Adjust path as needed
import '../../../models/user_model.dart'; // Adjust path as needed
import 'package:permission_handler/permission_handler.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _authService = AuthService();
  List<Map<String, dynamic>> _activeCalls = [];
  bool _isLoading = true;
  String? _errorMessage;
  bool _inCall = false; // Track if we're in a video call
  Map<String, dynamic>? _currentRoom; // Store the current room data
  RtcEngine? _engine; // Agora engine instance
  final List<int> _remoteUids = []; // Track remote users in the call

  @override
  void initState() {
    super.initState();
    _fetchActiveCalls();
    _initializeAgora();
  }

  Future<void> _initializeAgora() async {
    // Request permissions
    await [Permission.camera, Permission.microphone].request();
    if (await Permission.camera.isDenied || await Permission.microphone.isDenied) {
      setState(() {
        _errorMessage = 'Camera or microphone permission denied.';
      });
      return;
    }
    try {
      _engine = createAgoraRtcEngine();
      await _engine!.initialize(const RtcEngineContext(
        appId: "728434976dfc4d0996b68207cb155f71", // From your .env
        channelProfile: ChannelProfileType.channelProfileCommunication,
      ));

      // Set up event handlers
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
        ),
      );

      // Enable video and join a channel (we'll call this later)
      await _engine!.enableVideo();
      await _engine!.startPreview();
    } catch (e) {
      print('Agora initialization error: $e');
      setState(() {
        _errorMessage = 'Failed to initialize video call: $e';
      });
    }
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
          .filter('creator_id', 'in', friendIds);

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

        // Transition to video call interface
        setState(() {
          _inCall = true;
          _currentRoom = room;
        });

        // Join the Agora channel using the room_id as the channel name
        await _engine!.joinChannel(
          token: '', // Token can be empty for testing; use Agora token server in production
          channelId: room['room_id'].toString(),
          uid: 0, // 0 means Agora assigns a UID
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

  Future<void> _endCall() async {
    try {
      await _engine!.leaveChannel();
      await _authService.leaveVideoRoom(_currentRoom!['room_id'], (await _authService.getCurrentUser())!.id);
      setState(() {
        _inCall = false;
        _currentRoom = null;
        _remoteUids.clear();
      });
      _fetchActiveCalls(); // Refresh the call list
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: SafeArea(
        child: _inCall
            ? _buildVideoCallInterface()
            : _buildCallListView(),
      ),
    );
  }

  Widget _buildCallListView() {
    return Column(
      children: [
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator(color: Color(0xFF4CAF50)))
              : _activeCalls.isEmpty
                  ? const Center(
                      child: Text(
                        'No active calls from friends.',
                        style: TextStyle(color: Colors.white, fontSize: 16),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16.0),
                      itemCount: _activeCalls.length,
                      itemBuilder: (context, index) {
                        final call = _activeCalls[index];
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
                                ? () {
                                    print('Joining call: ${call['room_id']}');
                                  }
                                : null,
                          ),
                        );
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
              // Local video (creator's video)
              _engine != null
                  ? AgoraVideoView(
                      controller: VideoViewController(
                        rtcEngine: _engine!,
                        canvas: const VideoCanvas(uid: 0), // Local user
                      ),
                    )
                  : const Center(child: Text('Initializing video...', style: TextStyle(color: Colors.white))),
              // Remote videos (grid layout)
              if (_remoteUids.isNotEmpty)
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
}