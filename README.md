# Cliq

A social video and chat application built with Flutter. Connect with friends, share moments, and engage in real-time conversations.

## Table of Contents

- [Features](#features)
- [Tech Stack](#tech-stack)
- [Project Structure](#project-structure)
- [Installation](#installation)
- [Contributing](#contributing)
- [License](#license)

## Features

-   **User Authentication:** Secure sign-up, login, and logout functionality using Supabase Auth.
-   **Profile Management:** Users can create and update their profiles, including profile pictures.
-   **Real-time Chat:**
    -   Send and receive text messages instantly.
    -   Share images from the gallery.
    -   Record and send audio messages.
    -   Record and send short video messages.
    -   Real-time updates for new messages.
    -   Load older messages with pagination.
-   **Video Calling:**
    -   Create and join video call rooms powered by Agora.
    -   Invite friends to video calls.
-   **Friend System:**
    -   Search for other users.
    -   Send, accept, or decline friend requests.
    -   View friends list and remove friends.
-   **Connectivity Check:** Ensures users are aware of their internet connection status.

## Tech Stack

-   **Frontend:** Flutter
-   **Backend & Database:** Supabase (Authentication, Realtime Database, Storage)
-   **State Management:** Flutter Riverpod
-   **Routing:** GoRouter
-   **Video SDK:** Agora RTC Engine
-   **Key Packages:**
    -   `supabase_flutter`: Supabase integration.
    -   `flutter_riverpod`: State management.
    -   `go_router`: Navigation.
    -   `agora_rtc_engine`: Video calling.
    *   `image_picker`: Selecting images from gallery.
    *   `camera`: Accessing device camera for video messages.
    *   `video_player`: Playing video messages.
    *   `audio_waveforms`: Recording and displaying audio waveforms.
    *   `path_provider`: Accessing file system for storing temporary media.
    *   `permission_handler`: Requesting device permissions (camera, microphone).
    *   `cached_network_image`: Caching network images efficiently.
    *   `connectivity_plus`: Checking network connectivity.
    *   `loading_animation_widget`: UI loading indicators.
    *   `uuid`: Generating unique IDs.

## Project Structure

The project follows a feature-first approach for organizing code:

```
lib/
├── config/           # Configuration files (e.g., Supabase initialization)
├── features/         # Core application modules
│   ├── auth/         # Authentication screens, services, widgets
│   ├── chat/         # Chat screens, services, widgets
│   └── profile/      # User profile screens, services
├── models/           # Data models (e.g., UserModel, MessageModel)
├── services/         # Shared services (e.g., ConnectivityService)
├── utils/            # Utility functions and helpers
├── widgets/          # Reusable UI components (e.g., BottomNavBar)
├── router.dart       # Application routing setup using GoRouter
└── main.dart         # Main application entry point
```


### Installation

- apk file coming soon...

## Contributing

Contributions are welcome! If you have suggestions or want to contribute to the code, please:

1.  Fork the repository.
2.  Create a new branch (`git checkout -b feature/your-feature-name`).
3.  Make your changes.
4.  Commit your changes (`git commit -m 'Add some feature'`).
5.  Push to the branch (`git push origin feature/your-feature-name`).
6.  Open a Pull Request.

## License

All rights reserved.
