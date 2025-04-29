import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:cliq2/config/supabase.dart';
import '../../models/user_model.dart';
import '../../services/connectivity_service.dart';

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
  UserModel? getCurrentUser() {
    final user = supabase.auth.currentUser;
    if (user == null) return null;

    return null; // We'll implement fetching the profile later
  }
}