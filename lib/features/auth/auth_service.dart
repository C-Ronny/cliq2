import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:cliq2/config/supabase.dart';
import '../../models/user_model.dart';
import '../../services/connectivity_service.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';

class AuthService {
  final SupabaseClient supabase = SupabaseConfig.client;
  final ConnectivityService _connectivityService = ConnectivityService();

  // Sign up a new user (auth only)
  Future<void> signUp({
    required String email,
    required String password,
  }) async {
    // Check for internet connectivity
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
    // Check for internet connectivity
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

      // Fetch the user's profile
      final profileResponse = await supabase
          .from('profiles')
          .select()
          .eq('id', response.user!.id)
          .maybeSingle();

      if (profileResponse == null) {
        // Profile doesn't exist yet; user needs to create it
        throw Exception('Profile not found. Please complete your profile setup.');
      }

      return UserModel.fromJson(profileResponse);
    } catch (e) {
      if (e.toString().contains('SocketException') || e.toString().contains('ClientException')) {
        throw Exception('Failed to connect. Please try again.');
      }
      rethrow;
    }
  }

  // Log out the current user
  Future<void> logout() async {
    // Check for internet connectivity
    if (!(await _connectivityService.isConnected())) {
      throw Exception('No internet connection');
    }

    await supabase.auth.signOut();
  }

  // Get the current user (if logged in)
  Future<UserModel?> getCurrentUser() async {
    final user = supabase.auth.currentUser;
    if (user == null) return null;

    try {
      final profileResponse = await supabase
          .from('profiles')
          .select()
          .eq('id', user.id)
          .maybeSingle();

      if (profileResponse == null) return null;

      // If the user has a profile picture, generate a signed URL
      if (profileResponse['profile_picture'] != null) {
        final filePath = '${user.id}.jpg';
        final signedUrlResponse = await supabase.storage
            .from('avatars')
            .createSignedUrl(filePath, 60 * 60); // URL valid for 1 hour
        profileResponse['profile_picture'] = signedUrlResponse;
      }

      return UserModel.fromJson(profileResponse);
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
    String? profilePictureUrl,
  }) async {
    try {
      final updates = <String, dynamic>{};
      if (username != null) updates['username'] = username;
      if (firstName != null) updates['first_name'] = firstName;
      if (lastName != null) updates['last_name'] = lastName;
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

      // If the user has a profile picture, generate a signed URL
      if (profileResponse['profile_picture'] != null) {
        final filePath = '$userId.jpg';
        final signedUrlResponse = await supabase.storage
            .from('avatars')
            .createSignedUrl(filePath, 60 * 60); // URL valid for 1 hour
        profileResponse['profile_picture'] = signedUrlResponse;
      }

      return UserModel.fromJson(profileResponse);
    } catch (e) {
      throw Exception('Failed to update profile: $e');
    }
  }

  // Upload profile picture
  Future<String> uploadProfilePicture(String userId, XFile image) async {
    try {
      final file = File(image.path);
      final fileName = userId; // Use user ID as the file name
      final filePath = '$fileName.jpg';

      // Verify the user is authenticated
      if (supabase.auth.currentUser == null) {
        throw Exception('User not authenticated');
      }

      // Upload the file to the 'avatars' bucket
      await supabase.storage
          .from('avatars')
          .upload(filePath, file, fileOptions: const FileOptions(upsert: true));

      // Generate a signed URL for the uploaded file
      final signedUrl = await supabase.storage
          .from('avatars')
          .createSignedUrl(filePath, 60 * 60); // URL valid for 1 hour

      return signedUrl;
    } catch (e) {
      throw Exception('Failed to upload profile picture: $e');
    }
  }
}