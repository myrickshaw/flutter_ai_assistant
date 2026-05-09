/// Example: Integrating flutter_ai_assistant into a Flutter app.
///
/// The recommended provider is [FirebaseAiProvider] which routes Gemini
/// calls through Firebase AI Logic. The Gemini API key never ships in
/// your app binary; instead it lives on Firebase, which can also verify
/// a Firebase App Check token before forwarding the request.
library;

// ignore_for_file: avoid_print

import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter/material.dart';
import 'package:flutter_ai_assistant/flutter_ai_assistant.dart';

/// Minimal integration — wrap your app with [AiAssistant].
///
/// IMPORTANT: Add the [navigatorObserver] to your MaterialApp so the AI
/// can track which screen the user is on and navigate between screens.
///
/// ```dart
/// Future<void> main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   await Firebase.initializeApp(
///     options: DefaultFirebaseOptions.currentPlatform,
///   );
///   runApp(const MinimalExampleApp());
/// }
/// ```
class MinimalExampleApp extends StatelessWidget {
  const MinimalExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AiAssistant(
      config: AiAssistantConfig(
        // Acceptable: Firebase without App Check (still keeps the API
        // key off the device). For production, prefer the App-Check
        // variant shown in `fullIntegration()` below.
        provider: FirebaseAiProvider(
          firebaseAi: FirebaseAI.googleAI(),
          model: 'gemini-2.5-flash',
        ),
      ),
      // Use Builder to access the controller for the navigatorObserver.
      child: Builder(
        builder: (context) {
          final controller = AiAssistant.read(context);
          return MaterialApp(
            title: 'My App',
            // REQUIRED: Wire the observer so the AI can track navigation.
            navigatorObservers: [controller.navigatorObserver],
            home: const Scaffold(
              body: Center(child: Text('Your app content here')),
            ),
          );
        },
      ),
    );
  }
}

/// Full integration with all optional features configured.
///
/// Recommended posture for production: enable Firebase App Check and pass
/// it to `FirebaseAI.googleAI(...)`. App Check verifies a per-request
/// platform attestation token (Play Integrity / App Attest /
/// reCAPTCHA Enterprise) so only signed builds on attested devices can
/// invoke Gemini through your Firebase project.
void fullIntegration() {
  // 1. Choose your LLM provider (swap any time).
  //
  // Recommended: FirebaseAiProvider with App Check enabled. Requires
  // your host app to also call:
  //
  //   await FirebaseAppCheck.instance.activate(
  //     androidProvider: AndroidProvider.playIntegrity,
  //     appleProvider: AppleProvider.appAttest,
  //   );
  //
  // before runApp(). See firebase_app_check docs.
  //
  // ```dart
  // final provider = FirebaseAiProvider(
  //   firebaseAi: FirebaseAI.googleAI(
  //     appCheck: FirebaseAppCheck.instance,
  //     useLimitedUseAppCheckTokens: true, // future-proof for May 2026 replay protection
  //   ),
  //   model: 'gemini-2.5-flash',
  // );
  // ```
  //
  // For this example we show the no-App-Check variant to keep the
  // example dependency-free.
  final provider = FirebaseAiProvider(
    firebaseAi: FirebaseAI.googleAI(),
    model: 'gemini-2.5-flash',
  );

  // Alternative providers:
  // final provider = OpenAiProvider(apiKey: 'sk-...', model: 'gpt-4o');
  // final provider = ClaudeProvider(apiKey: 'sk-ant-...', model: 'claude-sonnet-4-20250514');

  // 2. Define custom tools for business logic the AI can't infer from UI.
  final bookRideTool = AiTool(
    name: 'book_ride',
    description:
        'Book a ride from pickup to destination. '
        'Use this when the user asks to book a ride and all details are confirmed.',
    parameters: {
      'pickup': const ToolParameter(
        type: 'string',
        description: 'Pickup address or location name.',
      ),
      'destination': const ToolParameter(
        type: 'string',
        description: 'Destination address or location name.',
      ),
      'vehicleType': const ToolParameter(
        type: 'string',
        description: 'Type of vehicle.',
        enumValues: ['auto', 'mini', 'sedan', 'suv'],
      ),
    },
    required: const ['pickup', 'destination'],
    handler: (args) async {
      // Call your actual booking API here.
      print('Booking: ${args['pickup']} → ${args['destination']}');
      return {'bookingId': 'BK-12345', 'status': 'confirmed'};
    },
  );

  // 3. Configure and wrap your app.
  runApp(
    AiAssistant(
      config: AiAssistantConfig(
        provider: provider,
        assistantName: 'My Assistant',
        voiceEnabled: true,
        showFloatingButton: true,

        // Optional: provide known routes for cross-screen navigation.
        knownRoutes: [
          'riderHomeScreen',
          'rideBookingScreen',
          'rideHistoryScreen',
          'profileScreen',
          'walletScreen',
          'settingsScreen',
        ],
        routeDescriptions: {
          'riderHomeScreen': 'Main home screen with map and ride booking',
          'rideBookingScreen': 'Book a new ride with pickup and destination',
          'rideHistoryScreen': 'View past ride history',
          'profileScreen': 'View and edit user profile',
          'walletScreen': 'View wallet balance and transactions',
          'settingsScreen': 'App settings and preferences',
        },

        // Optional: provide app-level state the AI should know about.
        globalContextProvider: () async => {
          'userName': 'John Doe',
          'walletBalance': 450.0,
          'activeRide': null,
          'isLoggedIn': true,
        },

        // Optional: custom navigation (useful with Stacked/auto_route).
        navigateToRoute: (routeName) async {
          // Use your router to navigate.
          // e.g., locator<NavigationService>().navigateTo(routeName);
          print('Navigating to: $routeName');
        },

        // Register custom business-logic tools.
        customTools: [bookRideTool],

        // Safety: require confirmation for purchases/bookings.
        confirmDestructiveActions: true,
      ),
      // Use Builder to access the controller from within the AiAssistant scope.
      child: Builder(
        builder: (context) {
          final controller = AiAssistant.read(context);
          return MaterialApp(
            title: 'My App',
            // IMPORTANT: Wire the navigator observer for route tracking & navigation.
            navigatorObservers: [controller.navigatorObserver],
            home: Scaffold(
              appBar: AppBar(title: const Text('My App')),
              body: const Center(child: Text('Your app content here')),
            ),
          );
        },
      ),
    ),
  );
}
