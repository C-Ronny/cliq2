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

class _MainScreenState extends State<MainScreen> {
  late int _selectedIndex;
  static const List<String> _routes = ['/main/home', '/main/friends', '/main/profile'];
  bool _isInVideoCallState = false;
  bool _isOverlayActive = false;

  @override
  void initState() {
    super.initState();
    _updateIndexBasedOnRoute();
  }

  void _updateIndexBasedOnRoute() {
    final location = widget.state.fullPath;
    setState(() {
      _selectedIndex = _routes.indexWhere((route) => location == route || location?.startsWith('$route/') == true);
      if (_selectedIndex == -1) _selectedIndex = 0;
    });
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
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
          : BottomNavigationBar(
              items: const <BottomNavigationBarItem>[
                BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
                BottomNavigationBarItem(icon: Icon(Icons.people), label: 'Friends'),
                BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Profile'),
              ],
              currentIndex: _selectedIndex,
              selectedItemColor: const Color(0xFF4CAF50),
              onTap: _onItemTapped,
            ),
    );
  }
}