import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:cliq2/config/supabase.dart';
import '../../models/user_model.dart';
import '../../services/connectivity_service.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';

class AuthService {
  final SupabaseClient supabase = SupabaseConfig.client;
  final ConnectivityService _connectivityService = ConnectivityService();
  UserModel? _cachedCurrentUser;

  // Sign up a new user (auth only)
  Future<void> signUp({
    required String email,
    required String password,
  }) async {
    if (!(await _connectivityService.isConnected())) {
      throw Exception('No internet connection');
    }

    try {
      final authResponse = await supabase.auth.signUp(
        email: email,
        password: password,
      );

      if (authResponse.user == null) {
        throw Exception('Invalid email or password');
      }
    } catch (e) {
      if (e.toString().contains('SocketException') || e.toString().contains('ClientException')) {
        throw Exception('Failed to connect. Please try again.');
      }
      rethrow;
    }
  }

  // Create user profile after email confirmation
  Future<UserModel> createProfile({
    required String userId,
    required String email,
    required String firstName,
    required String lastName,
  }) async {
    try {
      final profileData = {
        'id': userId,
        'email': email,
        'first_name': firstName,
        'last_name': lastName,
      };

      final profileResponse = await supabase
          .from('profiles')
          .insert(profileData)
          .select()
          .single();

      return UserModel.fromJson(profileResponse);
    } catch (e) {
      throw Exception('Failed to create profile: $e');
    }
  }

  // Log in an existing user
  Future<UserModel> login({
    required String email,
    required String password,
  }) async {
    if (!(await _connectivityService.isConnected())) {
      throw Exception('No internet connection');
    }

    try {
      final response = await supabase.auth.signInWithPassword(
        email: email,
        password: password,
      );

      if (response.user == null) {
        throw Exception('Invalid email or password');
      }

      final profileResponse = await supabase
          .from('profiles')
          .select()
          .eq('id', response.user!.id)
          .maybeSingle();

      if (profileResponse == null) {
        throw Exception('Profile not found. Please complete your profile setup.');
      }

      final user = UserModel.fromJson(profileResponse);
      _cachedCurrentUser = user;
      return user;
    } catch (e) {
      if (e.toString().contains('SocketException') || e.toString().contains('ClientException')) {
        throw Exception('Failed to connect. Please try again.');
      }
      rethrow;
    }
  }

  // Log out the current user
  Future<void> logout() async {
    if (!(await _connectivityService.isConnected())) {
      throw Exception('No internet connection');
    }

    await supabase.auth.signOut();
    _cachedCurrentUser = null;
  }

  // Get the current user (if logged in)
  Future<UserModel?> getCurrentUser() async {
    if (_cachedCurrentUser != null) {
      return _cachedCurrentUser;
    }

    final user = supabase.auth.currentUser;
    if (user == null) return null;

    try {
      final profileResponse = await supabase
          .from('profiles')
          .select()
          .eq('id', user.id)
          .maybeSingle();

      if (profileResponse == null) return null;

      if (profileResponse['profile_picture'] != null &&
          !profileResponse['profile_picture'].contains('signed')) {
        final filePath = '${user.id}.jpg';
        try {
          final signedUrlResponse = await supabase.storage
              .from('avatars')
              .createSignedUrl(filePath, 60 * 60)
              .timeout(const Duration(seconds: 5));
          profileResponse['profile_picture'] = signedUrlResponse;
        } catch (e) {
          print('Failed to fetch signed URL for current user ${user.id}: $e');
          profileResponse['profile_picture'] = null; // Fallback to null if the image doesn't exist
        }
      }

      final currentUser = UserModel.fromJson(profileResponse);
      _cachedCurrentUser = currentUser;
      return currentUser;
    } catch (e) {
      throw Exception('Failed to fetch user profile: $e');
    }
  }

  // Update user profile
  Future<UserModel> updateProfile({
    required String userId,
    String? username,
    String? firstName,
    String? lastName,
    String? email,
    String? profilePictureUrl,
  }) async {
    try {
      final updates = <String, dynamic>{};
      if (username != null) updates['username'] = username;
      if (firstName != null) updates['first_name'] = firstName;
      if (lastName != null) updates['last_name'] = lastName;
      if (email != null) updates['email'] = email;
      if (profilePictureUrl != null) updates['profile_picture'] = profilePictureUrl;

      if (updates.isEmpty) {
        throw Exception('No updates provided');
      }

      final profileResponse = await supabase
          .from('profiles')
          .update(updates)
          .eq('id', userId)
          .select()
          .single();

      if (profileResponse['profile_picture'] != null &&
          !profileResponse['profile_picture'].contains('signed')) {
        final filePath = '$userId.jpg';
        try {
          final signedUrlResponse = await supabase.storage
              .from('avatars')
              .createSignedUrl(filePath, 60 * 60)
              .timeout(const Duration(seconds: 5));
          profileResponse['profile_picture'] = signedUrlResponse;
        } catch (e) {
          print('Failed to fetch signed URL for updated user $userId: $e');
          profileResponse['profile_picture'] = null; // Fallback to null if the image doesn't exist
        }
      }

      final updatedUser = UserModel.fromJson(profileResponse);
      _cachedCurrentUser = updatedUser;
      return updatedUser;
    } catch (e) {
      throw Exception('Failed to update profile: $e');
    }
  }

  // Upload profile picture
  Future<String> uploadProfilePicture(String userId, XFile image) async {
    try {
      final file = File(image.path);
      final fileName = userId;
      final filePath = '$fileName.jpg';

      if (supabase.auth.currentUser == null) {
        throw Exception('User not authenticated');
      }

      await supabase.storage
          .from('avatars')
          .upload(filePath, file, fileOptions: const FileOptions(upsert: true));

      final signedUrl = await supabase.storage
          .from('avatars')
          .createSignedUrl(filePath, 60 * 60)
          .timeout(const Duration(seconds: 5));

      return signedUrl;
    } catch (e) {
      throw Exception('Failed to upload profile picture: $e');
    }
  }

  // Fetch signed URLs for a list of users concurrently
  Future<List<UserModel>> fetchSignedUrls(List<UserModel> users) async {
    final updatedUsers = List<UserModel>.from(users);
    final futures = <Future>[];

    for (var user in updatedUsers) {
      if (user.profilePicture != null && !user.profilePicture!.contains('signed')) {
        final filePath = '${user.id}.jpg';
        futures.add(
          supabase.storage
              .from('avatars')
              .createSignedUrl(filePath, 60 * 60)
              .timeout(const Duration(seconds: 5))
              .then((signedUrl) {
            user.profilePicture = signedUrl;
          }).catchError((e) {
            print('Failed to fetch signed URL for user ${user.id}: $e');
            user.profilePicture = null; // Fallback to null if the image doesn't exist
          }),
        );
      }
    }

    await Future.wait(futures);
    return updatedUsers;
  }

  // Get friend requests (incoming)
  Future<List<Map<String, dynamic>>> getFriendRequests() async {
    if (!(await _connectivityService.isConnected())) {
      throw Exception('No internet connection');
    }

    final currentUser = supabase.auth.currentUser;
    if (currentUser == null) {
      throw Exception('User not authenticated');
    }

    try {
      final response = await supabase
          .from('friend_requests')
          .select('id, from_user_id, status, profiles!friend_requests_from_user_id_fkey(id, username, email, first_name, last_name, profile_picture)')
          .eq('to_user_id', currentUser.id)
          .eq('status', 'pending');

      final requests = (response as List<dynamic>).map((request) {
        final user = UserModel.fromJson(request['profiles']);
        return {
          'request_id': request['id'],
          'sender': user,
        };
      }).toList();

      final futures = <Future>[];
      for (var request in requests) {
        final user = request['sender'] as UserModel;
        if (user.profilePicture != null && !user.profilePicture!.contains('signed')) {
          final filePath = '${user.id}.jpg';
          futures.add(
            supabase.storage
                .from('avatars')
                .createSignedUrl(filePath, 60 * 60)
                .timeout(const Duration(seconds: 5))
                .then((signedUrl) {
              user.profilePicture = signedUrl;
            }).catchError((e) {
              print('Failed to fetch signed URL for user ${user.id} in friend requests: $e');
              user.profilePicture = null; // Fallback to null if the image doesn't exist
            }),
          );
        }
      }

      await Future.wait(futures);
      return requests;
    } catch (e) {
      throw Exception('Failed to fetch friend requests: $e');
    }
  }

  // Send a friend request with duplicate check
  Future<void> sendFriendRequest(String toUserId) async {
    if (!(await _connectivityService.isConnected())) {
      throw Exception('No internet connection');
    }

    final currentUser = supabase.auth.currentUser;
    if (currentUser == null) {
      throw Exception('User not authenticated');
    }

    try {
      // Check for existing friend request in either direction
      final existingRequest = await supabase
          .from('friend_requests')
          .select()
          .or('and(from_user_id.eq.${currentUser.id},to_user_id.eq.$toUserId),and(from_user_id.eq.$toUserId,to_user_id.eq.${currentUser.id})')
          .maybeSingle();

      if (existingRequest != null) {
        throw Exception('A friend request already exists between you and this user.');
      }

      await supabase.from('friend_requests').insert({
        'from_user_id': currentUser.id,
        'to_user_id': toUserId,
        'status': 'pending',
      });
    } catch (e) {
      throw Exception('Failed to send friend request: $e');
    }
  }

  // Accept a friend request using RPC
  Future<void> acceptFriendRequest(String requestId) async {
    if (!(await _connectivityService.isConnected())) {
      throw Exception('No internet connection');
    }

    final currentUser = supabase.auth.currentUser;
    if (currentUser == null) {
      throw Exception('User not authenticated');
    }

    try {
      await supabase.rpc('accept_friend_request', params: {
        'p_request_id': requestId,
        'p_to_user_id': currentUser.id,
      });
    } catch (e) {
      throw Exception('Failed to accept friend request: $e');
    }
  }

  // Decline a friend request
  Future<void> declineFriendRequest(String requestId) async {
    if (!(await _connectivityService.isConnected())) {
      throw Exception('No internet connection');
    }

    final currentUser = supabase.auth.currentUser;
    if (currentUser == null) {
      throw Exception('User not authenticated');
    }

    try {
      await supabase
          .from('friend_requests')
          .update({'status': 'declined'})
          .eq('id', requestId)
          .eq('to_user_id', currentUser.id);
    } catch (e) {
      throw Exception('Failed to decline friend request: $e');
    }
  }

  // Get friends list
  Future<List<UserModel>> getFriends() async {
    if (!(await _connectivityService.isConnected())) {
      throw Exception('No internet connection');
    }

    final currentUser = supabase.auth.currentUser;
    if (currentUser == null) {
      throw Exception('User not authenticated');
    }

    try {
      final startTime = DateTime.now();
      final response = await supabase
          .from('friendships')
          .select('profiles!friendships_friend_id_fkey(id, username, first_name, last_name)')
          .eq('user_id', currentUser.id);

      final friends = (response as List<dynamic>)
          .map((friendship) => UserModel.fromJson(friendship['profiles']))
          .toList();

      final duration = DateTime.now().difference(startTime);
      print('Fetching friends took: ${duration.inMilliseconds}ms');

      return friends;
    } catch (e) {
      throw Exception('Failed to fetch friends: $e');
    }
  }

  // Remove a friend
  Future<void> removeFriend(String friendId) async {
    if (!(await _connectivityService.isConnected())) {
      throw Exception('No internet connection');
    }

    final currentUser = supabase.auth.currentUser;
    if (currentUser == null) {
      throw Exception('User not authenticated');
    }

    try {
      await supabase
          .from('friendships')
          .delete()
          .eq('user_id', currentUser.id)
          .eq('friend_id', friendId);

      await supabase
          .from('friendships')
          .delete()
          .eq('user_id', friendId)
          .eq('friend_id', currentUser.id);
    } catch (e) {
      throw Exception('Failed to remove friend: $e');
    }
  }

  Future<List<UserModel>> searchUsers({
    required String query,
    required Set<String> friendIds,
    required Set<String> requestIds,
  }) async {
    if (query.isEmpty) return [];

    final currentUser = supabase.auth.currentUser;
    if (currentUser == null) {
      throw Exception('User not authenticated');
    }

    try {
      print('Executing search query: $query');
      
      // Search for users by first_name, last_name, or username
      final response = await supabase
          .from('profiles')
          .select('*')
          .or('first_name.ilike.%$query%,last_name.ilike.%$query%,username.ilike.%$query%')
          .neq('id', currentUser.id) // Exclude current user
          .limit(20);

      print('Search response: $response');
      
      final users = response.map((data) => UserModel.fromJson(data)).toList();
      
      // Filter out users who are already friends or have pending requests
      final filteredUsers = users.where((user) {
        return !friendIds.contains(user.id) && !requestIds.contains(user.id);
      }).toList();
      
      print('Found ${filteredUsers.length} users after filtering');
      return filteredUsers;
    } catch (e) {
      print('Search error: $e');
      throw Exception('Failed to search users: $e');
    }
  }

  Future<void> fetchProfilePicture(UserModel user) async {
    if (user.profilePicture != null || user.id.isEmpty) return;
    
    try {
      // Simple approach - just list all files and filter manually
      final files = await supabase.storage
          .from('avatars')
          .list();
      
      // Filter files that start with the user's ID
      final userFiles = files.where((file) => 
          file.name.startsWith(user.id) || 
          file.name == '${user.id}.jpg' || 
          file.name == '${user.id}.png'
      );
      
      final hasProfilePicture = userFiles.isNotEmpty;
      
      if (hasProfilePicture) {
        final fileName = userFiles.first.name;
        final signedUrl = await supabase.storage
            .from('avatars')
            .createSignedUrl(fileName, 60);
        
        // Update the user model with the profile picture URL
        user.profilePicture = signedUrl;
      }
    } catch (e) {
      print('Failed to fetch profile picture for ${user.id}: $e');
    }
  }

  Future<Map<String, dynamic>> createVideoRoom({required String name}) async {
    final currentUser = supabase.auth.currentUser;
    if (currentUser == null) throw Exception('User not authenticated');

    print('Creating video room for user: ${currentUser.id}, name: $name');
    final roomData = {
      'name': name,
      'creator_id': currentUser.id,
      'participant_ids': [currentUser.id],
    };

    try {
      final response = await supabase
          .from('video_rooms')
          .insert(roomData)
          .select()
          .single();
      print('Video room created: $response');
      return response;
    } catch (e) {
      print('Error creating video room: $e');
      throw Exception('Failed to create video room: $e');
    }
  }
  

  Future<void> joinVideoRoom(String roomId, String userId) async {
    final room = await supabase
        .from('video_rooms')
        .select()
        .eq('room_id', roomId)
        .single();

    final participantIds = List<String>.from(room['participant_ids']);
    if (participantIds.length >= 4) throw Exception('Room is full');
    if (participantIds.contains(userId)) return; // Already in room

    participantIds.add(userId);
    await supabase
        .from('video_rooms')
        .update({'participant_ids': participantIds})
        .eq('room_id', roomId);
  }

  Future<void> toggleLockRoom(String roomId, bool lock) async {
    await supabase
        .from('video_rooms')
        .update({'locked': lock})
        .eq('room_id', roomId);
  }

  Future<void> sendCallInvite(String friendId, String roomId) async {
    final currentUser = await getCurrentUser();
    if (currentUser == null) throw Exception('User not authenticated');

    print('Sending invite: user=${currentUser.id}, friend=$friendId, room=$roomId');

    try {
      // Verify room exists before sending invite
      final room = await supabase
          .from('video_rooms')
          .select()
          .eq('room_id', roomId)
          .single()
          .maybeSingle();
      if (room == null) throw Exception('Invalid room ID');

      await supabase.from('call_invites').insert({
        'invited_user_id': friendId,
        'room_id': roomId,
        'status': 'pending',
      });
      print('Invite sent successfully');
    } catch (e) {
      print('Error sending invite: $e');
      throw Exception('Failed to send invite: $e');
    }
  }

  Future<void> acceptCallInvite(String inviteId, String roomId) async {
    final currentUser = supabase.auth.currentUser;
    if (currentUser == null) throw Exception('User not authenticated');

    try {
      // Fetch and validate the invite
      final invite = await supabase
          .from('call_invites')
          .select('room_id')
          .eq('id', inviteId)
          .eq('invited_user_id', currentUser.id)
          .maybeSingle();
      if (invite == null || invite['room_id'] == null) {
        throw Exception('Invalid invite or room ID');
      }

      // Update invite status
      await supabase
          .from('call_invites')
          .update({'status': 'accepted'})
          .eq('id', inviteId)
          .eq('invited_user_id', currentUser.id);

      // Join the video room with the validated room ID
      await joinVideoRoom(invite['room_id'], currentUser.id);
    } catch (e) {
      throw Exception('Failed to accept call invite: $e');
    }
  }

  Future<List<Map<String, dynamic>>> getCallInvites() async {
    final currentUser = supabase.auth.currentUser;
    if (currentUser == null) throw Exception('User not authenticated');

    final response = await supabase
        .from('call_invites')
        .select('*, room_id(name, creator_id(username, first_name, last_name), participant_ids)') 
        .eq('invited_user_id', currentUser.id)
        .eq('status', 'pending');

    return response;
  }

  Future<void> leaveVideoRoom(String roomId, String userId) async {
    print('Leaving video room: roomId=$roomId, userId=$userId');
    try {
      final room = await supabase
          .from('video_rooms')
          .select()
          .eq('room_id', roomId)
          .single();

      print('Fetched room: $room');
      final participantIds = List<String>.from(room['participant_ids']);
      if (!participantIds.contains(userId)) {
        throw Exception('User not in room');
      }

      participantIds.remove(userId);

      if (participantIds.isEmpty) {
        print('No participants left, deleting room');
        await supabase.from('video_rooms').delete().eq('room_id', roomId);
      } else {
        print('Updating participants: $participantIds');
        await supabase.rpc('safe_leave_video_room', params: {
          'p_room_id': roomId,
          'p_user_id': userId,
        });
      }
      print('Successfully left room');
    } catch (e) {
      print('Error leaving room: $e');
      throw Exception('Failed to leave room: $e');
    }
  }

  Future<void> declineCallInvite(String inviteId) async {
    final currentUser = supabase.auth.currentUser;
    if (currentUser == null) throw Exception('User not authenticated');

    try {
      await supabase
          .from('call_invites')
          .update({'status': 'declined'})
          .eq('id', inviteId)
          .eq('invited_user_id', currentUser.id);
    } catch (e) {
      throw Exception('Failed to decline call invite: $e');
    }
  }

  Future<Map<String, dynamic>> createConversation(List<String> participantIds) async {
    if (!(await _connectivityService.isConnected())) {
      throw Exception('No internet connection');
    }

    final currentUser = supabase.auth.currentUser;
    if (currentUser == null) {
      throw Exception('User not authenticated');
    }

    try {
      final response = await supabase
          .from('conversations')
          .insert({
            'participant_ids': participantIds,
          })
          .select()
          .single();

      return response;
    } catch (e) {
      throw Exception('Failed to create conversation: $e');
    }
  }


}