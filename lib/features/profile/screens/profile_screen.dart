import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../auth/auth_service.dart';
import '../../../models/user_model.dart';
import 'package:go_router/go_router.dart';

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
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _emailController = TextEditingController();
  XFile? _pickedImage;

  @override
  void initState() {
    super.initState();
    _fetchUserProfile();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    super.dispose();
  }

  Future<void> _fetchUserProfile() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final user = await _authService.getCurrentUser();
      if (user == null) {
        setState(() {
          _errorMessage = 'User not found. Please log in again.';
          _isLoading = false;
        });
        return;
      }

      setState(() {
        _user = user;
        _usernameController.text = user.username ?? '';
        _firstNameController.text = user.firstName ?? '';
        _lastNameController.text = user.lastName ?? '';
        _emailController.text = user.email ?? '';
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
        _isLoading = false;
      });
    }
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);

    if (pickedFile != null) {
      setState(() {
        _pickedImage = pickedFile;
      });

      try {
        final userId = _user!.id;
        final signedUrl = await _authService.uploadProfilePicture(userId, pickedFile);
        final updatedUser = await _authService.updateProfile(
          userId: userId,
          profilePictureUrl: signedUrl,
        );
        setState(() {
          _user = updatedUser;
          _pickedImage = null;
        });
      } catch (e) {
        setState(() {
          _errorMessage = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  Future<void> _updateProfile() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final updatedUser = await _authService.updateProfile(
        userId: _user!.id,
        username: _usernameController.text.isNotEmpty ? _usernameController.text : null,
        firstName: _firstNameController.text.isNotEmpty ? _firstNameController.text : null,
        lastName: _lastNameController.text.isNotEmpty ? _lastNameController.text : null,
        email: _emailController.text.isNotEmpty ? _emailController.text : null,
      );

      setState(() {
        _user = updatedUser;
        _isEditing = false;
        _isLoading = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Profile updated successfully!'),
          backgroundColor: Color(0xFF4CAF50),
          duration: Duration(seconds: 3),
        ),
      );
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
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


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(
                color: Color(0xFF4CAF50),
              ),
            )
          : _user == null
              ? Center(
                  child: Text(
                    _errorMessage ?? 'User not found.',
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 16,
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _fetchUserProfile,
                  color: const Color(0xFF4CAF50),
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24.0),
                      child: Column(
                        children: [
                          const SizedBox(height: 48),
                          Stack(
                            children: [
                              CircleAvatar(
                                radius: 55,
                                backgroundImage: _pickedImage != null
                                    ? FileImage(File(_pickedImage!.path))
                                    : _user!.profilePicture != null
                                        ? NetworkImage(_user!.profilePicture!)
                                        : null,
                                child: _pickedImage == null && _user!.profilePicture == null
                                    ? Text(
                                        _user!.firstName != null && _user!.firstName!.isNotEmpty
                                            ? _user!.firstName![0].toUpperCase()
                                            : 'U',
                                        style: const TextStyle(
                                          fontSize: 40,
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      )
                                    : null,
                              ),
                              Positioned(
                                bottom: 0,
                                right: 0,
                                child: GestureDetector(
                                  onTap: _pickImage,
                                  child: Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: const BoxDecoration(
                                      color: Color(0xFF4CAF50),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.camera_alt,
                                      color: Colors.white,
                                      size: 15,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            _user!.username ?? 'No username',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${_user!.firstName ?? ''} ${_user!.lastName ?? ''}', 
                            style: const TextStyle(
                              color: Color(0xFF4CAF50),
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 24),
                          if (_errorMessage != null) ...[
                            Text(
                              _errorMessage!,
                              style: const TextStyle(
                                color: Colors.redAccent,
                                fontSize: 14,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),
                          ],
                          Form(
                            key: _formKey,
                            child: Column(
                              children: [
                                TextFormField(
                                  controller: _usernameController,
                                  style: const TextStyle(color: Colors.white),
                                  decoration: InputDecoration(
                                    labelText: 'Username',
                                    labelStyle: const TextStyle(color: Color(0xFF4CAF50)),
                                    filled: true,
                                    fillColor: const Color(0xFF121212), // Match the scaffold background
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Color(0xFFB3B3B3)),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Color.fromARGB(255, 89, 238, 94)),
                                    ),
                                    disabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Color(0xFF4CAF50)),
                                    ),
                                  ),
                                  enabled: _isEditing,
                                  validator: (value) {
                                    if (value != null && value.length < 3 && value.isNotEmpty) {
                                      return 'Username must be at least 3 characters';
                                    }
                                    return null;
                                  },
                                ),
                                const SizedBox(height: 16),
                                TextFormField(
                                  controller: _firstNameController,
                                  style: const TextStyle(color: Colors.white),
                                  decoration: InputDecoration(
                                    labelText: 'First Name',
                                    labelStyle: const TextStyle(color: Color(0xFF4CAF50)),
                                    filled: true,
                                    fillColor: const Color(0xFF121212), // Match the scaffold background
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Color(0xFFB3B3B3)),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Color.fromARGB(255, 89, 238, 94)),
                                    ),
                                    disabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Color(0xFF4CAF50)),
                                    ),
                                  ),
                                  enabled: _isEditing,
                                  validator: (value) {
                                    if (value != null && value.length < 2 && value.isNotEmpty) {
                                      return 'First name must be at least 2 characters';
                                    }
                                    return null;
                                  },
                                ),
                                const SizedBox(height: 16),
                                TextFormField(
                                  controller: _lastNameController,
                                  style: const TextStyle(color: Colors.white),
                                  decoration: InputDecoration(
                                    labelText: 'Last Name',
                                    labelStyle: const TextStyle(color: Color(0xFF4CAF50)),
                                    filled: true,
                                    fillColor: const Color(0xFF121212), // Match the scaffold background
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Color(0xFFB3B3B3)),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Color.fromARGB(255, 89, 238, 94)),
                                    ),
                                    disabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Color(0xFF4CAF50)),
                                    ),
                                  ),
                                  enabled: _isEditing,
                                  validator: (value) {
                                    if (value != null && value.length < 2 && value.isNotEmpty) {
                                      return 'Last name must be at least 2 characters';
                                    }
                                    return null;
                                  },
                                ),
                                const SizedBox(height: 16),
                                TextFormField(
                                  controller: _emailController,
                                  style: const TextStyle(color: Colors.white),
                                  decoration: InputDecoration(
                                    labelText: 'Email',
                                    labelStyle: const TextStyle(color: Color(0xFF4CAF50)),
                                    filled: true,
                                    fillColor: const Color(0xFF121212), // Match the scaffold background
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Color(0xFFB3B3B3)),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Color.fromARGB(255, 89, 238, 94)),
                                    ),
                                    disabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Color(0xFF4CAF50)),
                                    ),
                                  ),
                                  enabled: _isEditing,
                                  validator: (value) {
                                    if (value == null || value.trim().isEmpty) {
                                      return 'Email address is required';
                                    }

                                    final emailRegex = RegExp(
                                      r'^[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+$',
                                    );

                                    if (!emailRegex.hasMatch(value)) {
                                      return 'Please enter a valid email address';
                                    }

                                    return null;
                                  },
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 24),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              ElevatedButton(
                                onPressed: _isEditing ? _updateProfile : () => setState(() => _isEditing = true),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF4CAF50),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 32,
                                    vertical: 12,
                                  ),
                                ),
                                child: Text(
                                  _isEditing ? 'Save' : 'Edit Profile',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 16),
                              if (_isEditing)
                                ElevatedButton(
                                  onPressed: () {
                                    setState(() {
                                      _isEditing = false;
                                      _usernameController.text = _user!.username ?? '';
                                      _firstNameController.text = _user!.firstName ?? '';
                                      _lastNameController.text = _user!.lastName ?? '';
                                      _emailController.text = _user!.email ?? '';
                                    });
                                  },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.redAccent,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 32,
                                      vertical: 12,
                                    ),
                                  ),
                                  child: const Text(
                                    'Cancel',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 24),
                          TextButton(
                            onPressed: _logout,
                            child: const Text(
                              'Logout',
                              style: TextStyle(
                                color: Colors.redAccent,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(height: 80),
                        ],
                      ),
                    ),
                  ),
                ),
    );
  }
}