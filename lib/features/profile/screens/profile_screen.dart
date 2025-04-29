import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../auth/auth_service.dart';
import '../../../models/user_model.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:io';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _authService = AuthService();
  UserModel? _user;
  String? _errorMessage;
  bool _isLoading = true;
  bool _isEditing = false;
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _usernameController = TextEditingController();
  File? _selectedImage;
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _fetchUserProfile();
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _usernameController.dispose();
    super.dispose();
  }

  Future<void> _fetchUserProfile() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final user = await _authService.getCurrentUser();
      setState(() {
        _user = user;
        _firstNameController.text = user?.firstName ?? '';
        _lastNameController.text = user?.lastName ?? '';
        _usernameController.text = user?.username ?? '';
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to load profile. Please try again.';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _logout() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await _authService.logout();
      context.go('/login');
    } catch (e) {
      final error = e.toString().replaceFirst('Exception: ', '');
      setState(() {
        _errorMessage = error == 'No internet connection'
            ? 'No internet connection. Please check your network and try again.'
            : 'Failed to log out. Please try again.';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<bool> _requestGalleryPermission() async {
    // Check if permission is already granted
    final status = await Permission.photos.status;
    if (status.isGranted) {
      return true;
    }

    // Show a modal to explain why we need gallery access
    bool? shouldProceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Gallery Access Needed'),
        content: const Text(
          'This app needs access to your gallery to select a profile picture. Would you like to grant permission?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Deny'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Allow'),
          ),
        ],
      ),
    );

    // If the user denies the request, return false
    if (shouldProceed != true) {
      setState(() {
        _errorMessage = 'Gallery access denied. You can enable it later in settings.';
      });
      return false;
    }

    // Request the permission
    final newStatus = await Permission.photos.request();
    if (newStatus.isGranted) {
      return true;
    } else {
      // If denied (including permanently denied), show another dialog
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Permission Denied'),
          content: const Text(
            'Gallery access was denied. Please enable it in settings to select a profile picture.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                openAppSettings();
                Navigator.pop(context);
              },
              child: const Text('Open Settings'),
            ),
          ],
        ),
      );
      setState(() {
        _errorMessage = 'Gallery access denied. Please enable permissions in settings.';
      });
      return false;
    }
  }

  Future<void> _pickImage() async {
    final hasPermission = await _requestGalleryPermission();
    if (!hasPermission) {
      return;
    }

    try {
      final pickedFile = await _picker.pickImage(source: ImageSource.gallery);
      if (pickedFile != null) {
        setState(() {
          _selectedImage = File(pickedFile.path);
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to pick image: $e';
      });
    }
  }

  Future<void> _saveProfile() async {
    if (_user == null) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      String? profilePictureUrl;
      if (_selectedImage != null) {
        profilePictureUrl = await _authService.uploadProfilePicture(_user!.id, XFile(_selectedImage!.path));
        // Clear the image cache for the old profile picture URL
        if (_user!.profilePicture != null) {
          await NetworkImage(_user!.profilePicture!).evict();
        }
      }

      final updatedUser = await _authService.updateProfile(
        userId: _user!.id,
        firstName: _firstNameController.text.trim().isNotEmpty ? _firstNameController.text.trim() : null,
        lastName: _lastNameController.text.trim().isNotEmpty ? _lastNameController.text.trim() : null,
        username: _usernameController.text.trim().isNotEmpty ? _usernameController.text.trim() : null,
        profilePictureUrl: profilePictureUrl,
      );

      setState(() {
        _user = updatedUser;
        _isEditing = false;
        _selectedImage = null;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to update profile: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: RefreshIndicator(
        onRefresh: _fetchUserProfile,
        color: const Color(0xFF4CAF50),
        child: _isLoading
            ? const Center(
                child: CircularProgressIndicator(
                  color: Color(0xFF4CAF50),
                ),
              )
            : _user == null
                ? Center(
                    child: SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text(
                            'No profile found.',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                            ),
                          ),
                          const SizedBox(height: 16),
                          if (_errorMessage != null)
                            Text(
                              _errorMessage!,
                              style: const TextStyle(
                                color: Colors.redAccent,
                                fontSize: 14,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          const SizedBox(height: 16),
                          ElevatedButton(
                            onPressed: _fetchUserProfile,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF4CAF50),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: const Text(
                              'Retry',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 40), // Top padding
                          Center(
                            child: Stack(
                              children: [
                                GestureDetector(
                                  onTap: _isEditing ? _pickImage : null,
                                  child: CircleAvatar(
                                    radius: 60,
                                    backgroundImage: _selectedImage != null
                                        ? FileImage(_selectedImage!)
                                        : _user!.profilePicture != null
                                            ? NetworkImage(_user!.profilePicture!)
                                            : null,
                                    child: _selectedImage == null && _user!.profilePicture == null
                                        ? Text(
                                            _user!.firstName[0].toUpperCase(),
                                            style: const TextStyle(
                                              fontSize: 40,
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          )
                                        : null,
                                  ),
                                ),
                                if (_isEditing)
                                  Positioned(
                                    bottom: 0,
                                    right: 0,
                                    child: Container(
                                      padding: const EdgeInsets.all(4),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF4CAF50),
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: const Color(0xFF121212),
                                          width: 2,
                                        ),
                                      ),
                                      child: const Icon(
                                        Icons.edit,
                                        color: Colors.white,
                                        size: 20,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          Center(
                            child: Text(
                              '${_user!.firstName} ${_user!.lastName}',
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Profile Details',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                              ElevatedButton(
                                onPressed: () {
                                  setState(() {
                                    _isEditing = !_isEditing;
                                    if (!_isEditing) {
                                      _saveProfile();
                                    }
                                  });
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF4CAF50),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                child: Text(
                                  _isEditing ? 'Save Profile' : 'Edit Profile',
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          _buildProfileField(
                            label: 'Username',
                            value: _user!.username ?? 'Not set',
                            isEditable: true,
                            controller: _usernameController,
                          ),
                          const SizedBox(height: 16),
                          _buildProfileField(
                            label: 'First Name',
                            value: _user!.firstName,
                            isEditable: true,
                            controller: _firstNameController,
                          ),
                          const SizedBox(height: 16),
                          _buildProfileField(
                            label: 'Last Name',
                            value: _user!.lastName,
                            isEditable: true,
                            controller: _lastNameController,
                          ),
                          const SizedBox(height: 16),
                          _buildProfileField(
                            label: 'Email',
                            value: _user!.email,
                            isEditable: false,
                          ),
                          if (_errorMessage != null) ...[
                            const SizedBox(height: 16),
                            Text(
                              _errorMessage!,
                              style: const TextStyle(
                                color: Colors.redAccent,
                                fontSize: 14,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                          const SizedBox(height: 32),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 80.0), // Space for bottom navigation bar
                            child: SizedBox(
                              width: double.infinity,
                              height: 50,
                              child: ElevatedButton(
                                onPressed: _logout,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.redAccent,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                child: const Text(
                                  'Log Out',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
      ),
    );
  }

  Widget _buildProfileField({
    required String label,
    required String value,
    required bool isEditable,
    TextEditingController? controller,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            color: Color(0xFFB3B3B3),
          ),
        ),
        const SizedBox(height: 8),
        _isEditing && isEditable
            ? TextField(
                controller: controller,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0xFF1E1E1E),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
              )
            : Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                  ),
                ),
              ),
      ],
    );
  }
}