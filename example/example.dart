/// Example: Integrating flutter_ai_assistant into the Yatri app.
///
/// This shows the minimal setup required — zero annotations, zero boilerplate.
/// Just wrap your app and provide an LLM API key.
library;

// ignore_for_file: avoid_print

import 'package:flutter/material.dart';
import 'package:flutter_ai_assistant/flutter_ai_assistant.dart';

/// Minimal integration — wrap your app with [AiAssistant].
///
/// IMPORTANT: Add the [navigatorObserver] to your MaterialApp so the AI
/// can track which screen the user is on and navigate between screens.
///
/// ```dart
/// void main() {
///   runApp(
///     AiAssistant(
///       config: AiAssistantConfig(
///         provider: GeminiProvider(apiKey: 'YOUR_GEMINI_API_KEY'),
///       ),
///       child: const MyApp(),
///     ),
///   );
/// }
/// ```
class MinimalExampleApp extends StatelessWidget {
  const MinimalExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AiAssistant(
      config: AiAssistantConfig(
        provider: GeminiProvider(apiKey: 'YOUR_GEMINI_API_KEY'),
      ),
      // Use Builder to access the controller for the navigatorObserver.
      child: Builder(builder: (context) {
        final controller = AiAssistant.read(context);
        return MaterialApp(
          title: 'My App',
          // REQUIRED: Wire the observer so the AI can track navigation.
          navigatorObservers: [controller.navigatorObserver],
          home: const Scaffold(
            body: Center(child: Text('Your app content here')),
          ),
        );
      }),
    );
  }
}

/// Full integration with all optional features configured.
///
/// This example shows what a Yatri-style app integration would look like
/// with all the bells and whistles enabled.
void fullIntegration() {
  // 1. Choose your LLM provider (swap any time).
  final provider = GeminiProvider(
    apiKey: 'YOUR_API_KEY',
    model: 'gemini-2.0-flash', // fast + cheap for mobile
  );

  // Alternative providers:
  // final provider = OpenAiProvider(apiKey: 'sk-...', model: 'gpt-4o');
  // final provider = ClaudeProvider(apiKey: 'sk-ant-...', model: 'claude-sonnet-4-20250514');

  // 2. Define custom tools for business logic the AI can't infer from UI.
  final bookRideTool = AiTool(
    name: 'book_ride',
    description: 'Book a ride from pickup to destination. '
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
        assistantName: 'Yatri Assistant',
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
      child: Builder(builder: (context) {
        final controller = AiAssistant.read(context);
        return MaterialApp(
          title: 'Yatri',
          // IMPORTANT: Wire the navigator observer for route tracking & navigation.
          navigatorObservers: [controller.navigatorObserver],
          home: Scaffold(
            appBar: AppBar(title: const Text('Yatri')),
            body: const Center(child: Text('Your app content here')),
          ),
        );
      }),
    ),
  );
}
