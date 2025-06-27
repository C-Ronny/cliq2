# Cliq

A social video and chat application built with Flutter. Connect with friends, share moments, and engage in real-time conversations.

## Table of Contents

- [Features](#features)
- [Tech Stack](#tech-stack)
- [Project Structure](#project-structure)
- [Getting Started](#getting-started)
  - [Prerequisites](#prerequisites)
  - [Installation](#installation)
  - [Environment Variables](#environment-variables)
  - [Running the App](#running-the-app)
- [Building the App](#building-the-app)
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
    -   (Functionality for locking rooms and managing participants exists in code).
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
    *   `flutter_dotenv`: Managing environment variables.
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

## Getting Started

Follow these instructions to get a copy of the project up and running on your local machine for development and testing purposes.

### Prerequisites

-   Flutter SDK: Make sure you have Flutter installed. Refer to the [Flutter official documentation](https://flutter.dev/docs/get-started/install).
-   A code editor like VS Code or Android Studio.
-   An emulator or a physical device to run the app.

### Installation

1.  **Clone the repository:**
    ```bash
    git clone <repository-url>
    cd cliq2
    ```

2.  **Install dependencies:**
    ```bash
    flutter pub get
    ```

### Environment Variables

This project uses a `.env` file to manage environment-specific configurations.

1.  Create a file named `.env` in the root directory of the project.
2.  Add the following environment variables with your specific keys:

    ```env
    SUPABASE_URL=your_supabase_url
    SUPABASE_ANON_KEY=your_supabase_anon_key
    AGORA_APP_ID=your_agora_app_id
    ```

    -   `SUPABASE_URL` and `SUPABASE_ANON_KEY` can be obtained from your Supabase project settings.
    -   `AGORA_APP_ID` can be obtained from your Agora project dashboard.

    **Note:** Ensure the `.env` file is added to your `.gitignore` to prevent committing sensitive keys.

### Running the App

Once the dependencies are installed and the environment variables are set up, you can run the app using:

```bash
flutter run
```

## Building the App

(This section can be expanded with specific build commands for different platforms if needed.)

For example, to build an Android APK:
```bash
flutter build apk --release
```

To build for iOS:
```bash
flutter build ios --release
```

## Contributing

Contributions are welcome! If you have suggestions or want to contribute to the code, please:

1.  Fork the repository.
2.  Create a new branch (`git checkout -b feature/your-feature-name`).
3.  Make your changes.
4.  Commit your changes (`git commit -m 'Add some feature'`).
5.  Push to the branch (`git push origin feature/your-feature-name`).
6.  Open a Pull Request.

Please ensure your code adheres to the existing coding style and includes tests where applicable.

## License

(Consider adding a license, e.g., MIT License. If no license is chosen, this can be removed or stated as "All rights reserved.")
