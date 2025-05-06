import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class MainScreen extends StatefulWidget {
  final Widget child;
  final GoRouterState state;
  final Function(bool inCall, bool overlayActive) updateCallState;

  const MainScreen({
    super.key,
    required this.child,
    required this.state,
    required this.updateCallState,
  });

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with SingleTickerProviderStateMixin {
  late int _selectedIndex;
  static const List<String> _routes = ['/main/home', '/main/friends', '/main/chats', '/main/profile'];
  bool _isInVideoCallState = false;
  bool _isOverlayActive = false;
  late AnimationController _animationController;
  
  // Define the tab items with their icons and labels
  final List<Map<String, dynamic>> _tabItems = [
    {'icon': Icons.home_rounded, 'label': 'Home'},
    {'icon': Icons.people_alt_rounded, 'label': 'Friends'},
    {'icon': Icons.chat_bubble_rounded, 'label': 'Chats'},
    {'icon': Icons.person_rounded, 'label': 'Profile'},
  ];

  @override
  void initState() {
    super.initState();
    _updateIndexBasedOnRoute();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _animationController.forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(MainScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state.fullPath != widget.state.fullPath) {
      _updateIndexBasedOnRoute();
    }
  }

  void _updateIndexBasedOnRoute() {
    final location = widget.state.fullPath;
    setState(() {
      _selectedIndex = _routes.indexWhere((route) => location == route || location?.startsWith('$route/') == true);
      if (_selectedIndex == -1) _selectedIndex = 0;
    });
  }

  void _onItemTapped(int index) {
    if (_selectedIndex == index) return;
    
    setState(() {
      _selectedIndex = index;
    });
    
    _animationController.reset();
    _animationController.forward();
    
    context.go(_routes[index]);
  }

  void updateCallState({required bool inCall, required bool overlayActive}) {
    setState(() {
      _isInVideoCallState = inCall;
      _isOverlayActive = overlayActive;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: widget.child,
      bottomNavigationBar: (_selectedIndex == 0 && (_isInVideoCallState || _isOverlayActive))
          ? null
          : _buildCustomNavBar(),
    );
  }

  Widget _buildCustomNavBar() {
    return Container(
      height: 70,
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: List.generate(_tabItems.length, (index) {
            final isSelected = _selectedIndex == index;
            return _buildNavItem(
              icon: _tabItems[index]['icon'],
              label: _tabItems[index]['label'],
              isSelected: isSelected,
              onTap: () => _onItemTapped(index),
            );
          }),
        ),
      ),
    );
  }

  Widget _buildNavItem({
    required IconData icon,
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF4CAF50).withOpacity(0.1) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: isSelected ? const Color(0xFF4CAF50) : Colors.grey,
              size: 24,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? const Color(0xFF4CAF50) : Colors.grey,
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
