import 'package:flutter/material.dart';
import '../../../models/user_model.dart';
import '../../auth/auth_service.dart';

class FriendProfileScreen extends StatefulWidget {
  final UserModel friend;

  const FriendProfileScreen({super.key, required this.friend});

  @override
  State<FriendProfileScreen> createState() => _FriendProfileScreenState();
}

class _FriendProfileScreenState extends State<FriendProfileScreen> {
  final _authService = AuthService();
  bool _loadingProfilePicture = true;
  
  @override
  void initState() {
    super.initState();
    _loadProfilePicture();
  }
  
  Future<void> _loadProfilePicture() async {
    await _authService.fetchProfilePicture(widget.friend);
    if (mounted) {
      setState(() {
        _loadingProfilePicture = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24.0),
        child: Column(
          children: [
            const SizedBox(height: 24),
            CircleAvatar(
              radius: 50,
              backgroundColor: Colors.grey[700],
              backgroundImage: widget.friend.profilePicture != null && widget.friend.profilePicture!.isNotEmpty
                  ? NetworkImage(widget.friend.profilePicture!)
                  : null,
              child: (widget.friend.profilePicture == null || widget.friend.profilePicture!.isEmpty)
                  ? Text(
                      (widget.friend.firstName ?? 'U')[0].toUpperCase(),
                      style: const TextStyle(
                        fontSize: 40,
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    )
                  : null,
            ),
            const SizedBox(height: 16),
            Text(
              widget.friend.username ?? 'No username',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${widget.friend.firstName ?? 'Unknown'} ${widget.friend.lastName ?? ''}',
              style: const TextStyle(
                color: Color(0xFFB3B3B3),
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () {
                // Implement messaging or chat functionality
              },
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
              child: const Text(
                'Message',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}