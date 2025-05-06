import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  final List<Map<String, String>> onboardingData = [
    {
      'title': 'Welcome to Cliq',
      'description': 'Connect with friends through video and chat!',
    },
    {
      'title': 'Video Calls',
      'description': 'Join up to 4 friends in a video room.',
    },
    {
      'title': 'Real-Time Chat',
      'description': 'Send messages, images, and voice notes instantly.',
    },
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                onPageChanged: (index) {
                  setState(() {
                    _currentPage = index;
                  });
                },
                itemCount: onboardingData.length,
                itemBuilder: (context, index) {
                  return Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Add illustration container
                        Container(
                          width: 200,
                          height: 200,
                          margin: const EdgeInsets.only(bottom: 40),
                          decoration: BoxDecoration(
                            color: const Color(0xFF4CAF50).withOpacity(0.1),
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: Icon(
                              index == 0 
                                ? Icons.chat_bubble_outline
                                : index == 1 
                                  ? Icons.videocam_outlined
                                  : Icons.message_outlined,
                              color: const Color(0xFF4CAF50),
                              size: 80,
                            ),
                          ),
                        ),
                        Text(
                          onboardingData[index]['title']!,
                          style: const TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFFFFFFFF),
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          onboardingData[index]['description']!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 18,
                            color: Color(0xFFB3B3B3),
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            // Improved indicator dots
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  onboardingData.length,
                  (index) => AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    margin: const EdgeInsets.symmetric(horizontal: 5),
                    width: _currentPage == index ? 24 : 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: _currentPage == index
                          ? const Color(0xFF4CAF50)
                          : const Color(0xFF333333),
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 40),
            // Improved button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
              child: SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  onPressed: () {
                    if (_currentPage == onboardingData.length - 1) {
                      context.go('/login');
                    } else {
                      _pageController.nextPage(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                      );
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4CAF50),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    _currentPage == onboardingData.length - 1 ? 'Get Started' : 'Next',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
            // Skip button
            if (_currentPage < onboardingData.length - 1)
              Padding(
                padding: const EdgeInsets.only(bottom: 24.0),
                child: TextButton(
                  onPressed: () {
                    context.go('/login');
                  },
                  child: const Text(
                    'Skip',
                    style: TextStyle(
                      color: Color(0xFFB3B3B3),
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              )
            else
              const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
