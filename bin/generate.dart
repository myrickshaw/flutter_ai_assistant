// ignore_for_file: avoid_print
/// LLM-powered app context manifest generator.
///
/// Scans a Flutter app's route definitions and source code, sends each
/// screen's widget source to Gemini for analysis, and generates a complete
/// Dart manifest file (`AiAppManifest`) for use by the AI assistant.
///
/// Usage:
///   dart run flutter_ai_assistant:generate \
///     --routes-file=lib/models/routes.dart \
///     --router-file=lib/app/router.dart \
///     --api-key=YOUR_GEMINI_KEY \
///     --output=lib/ai_app_manifest.g.dart
///
/// Or with env file:
///   dart run flutter_ai_assistant:generate --env=.env.staging
library;

import 'dart:convert';
import 'dart:io';

// ---------------------------------------------------------------------------
// CLI entry point
// ---------------------------------------------------------------------------

Future<void> main(List<String> args) async {
  final config = _parseArgs(args);

  print('=== flutter_ai_assistant: generate app manifest ===');
  print('Routes file : ${config.routesFile}');
  print('Router file : ${config.routerFile}');
  print('Output      : ${config.output}');
  print('');

  // 1. Parse route constants.
  print('[1/6] Parsing route constants...');
  final routeConstants = _parseRoutesFile(
    config.routesFile,
    config.routesClass,
  );
  print('  Found ${routeConstants.length} route constants');

  // 2. Parse router to get route → view class mapping.
  print('[2/6] Parsing router for view class mappings...');
  final routeToClass = _parseRouterFile(config.routerFile, config.routesClass);
  print('  Mapped ${routeToClass.length} routes to view classes');

  // 3. Find view source files.
  print('[3/6] Finding view source files...');
  final libDir = _findLibDir(config.routesFile);
  final viewSources = <String, String>{}; // routeConstant → source code
  for (final entry in routeToClass.entries) {
    final className = entry.value;
    final source = _findClassSource(libDir, className);
    if (source != null) {
      viewSources[entry.key] = source;
    }
  }
  print(
    '  Found source for ${viewSources.length}/${routeToClass.length} view classes',
  );

  // 4. Send to Gemini for analysis.
  print('[4/6] Analyzing screens with Gemini...');
  final screenAnalyses = <String, Map<String, dynamic>>{};
  int processed = 0;
  for (final entry in viewSources.entries) {
    final routeConstant = entry.key;
    final routeValue = routeConstants[routeConstant] ?? '/$routeConstant';
    processed++;
    print(
      '  [$processed/${viewSources.length}] Analyzing $routeConstant ($routeValue)...',
    );

    try {
      final analysis = await _analyzeScreen(
        config.apiKey,
        routeConstant,
        routeValue,
        entry.value,
        config.model,
      );
      if (analysis != null) {
        screenAnalyses[routeConstant] = analysis;
      }
    } catch (e) {
      print('    WARNING: Failed to analyze $routeConstant: $e');
    }

    // Rate limiting: brief pause between requests.
    if (processed < viewSources.length) {
      await Future.delayed(const Duration(milliseconds: 500));
    }
  }
  print('  Successfully analyzed ${screenAnalyses.length} screens');

  // 5. Generate flows by sending all screen analyses to LLM.
  print('[5/6] Generating common flows...');
  List<Map<String, dynamic>> flows = [];
  if (screenAnalyses.isNotEmpty) {
    try {
      flows = await _generateFlows(
        config.apiKey,
        routeConstants,
        screenAnalyses,
        config.model,
      );
      print('  Generated ${flows.length} flows');
    } catch (e) {
      print('  WARNING: Failed to generate flows: $e');
    }
  }

  // 6. Generate the Dart file.
  print('[6/6] Generating Dart manifest file...');
  final dartCode = _generateDartFile(
    routeConstants: routeConstants,
    routesClass: config.routesClass,
    routesFileImport: config.routesFileImport,
    screenAnalyses: screenAnalyses,
    flows: flows,
    appName: config.appName,
  );
  File(config.output).writeAsStringSync(dartCode);
  print('');
  print('Generated: ${config.output}');
  print('Screens: ${screenAnalyses.length}');
  print('Flows: ${flows.length}');
  print('');
  print('Done! Review the generated file and edit as needed.');
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

class _Config {
  final String routesFile;
  final String routerFile;
  final String routesClass;
  final String routesFileImport;
  final String apiKey;
  final String output;
  final String appName;
  final String model;

  const _Config({
    required this.routesFile,
    required this.routerFile,
    required this.routesClass,
    required this.routesFileImport,
    required this.apiKey,
    required this.output,
    required this.appName,
    required this.model,
  });
}

_Config _parseArgs(List<String> args) {
  String? routesFile;
  String? routerFile;
  String routesClass = 'Routes';
  String routesFileImport = 'models/routes.dart';
  String? apiKey;
  String output = 'lib/ai_app_manifest.g.dart';
  String appName = 'App';
  String model = 'gemini-2.0-flash';
  String? envFile;

  for (final arg in args) {
    if (arg.startsWith('--routes-file=')) {
      routesFile = arg.split('=').sublist(1).join('=');
    } else if (arg.startsWith('--router-file=')) {
      routerFile = arg.split('=').sublist(1).join('=');
    } else if (arg.startsWith('--routes-class=')) {
      routesClass = arg.split('=').sublist(1).join('=');
    } else if (arg.startsWith('--routes-import=')) {
      routesFileImport = arg.split('=').sublist(1).join('=');
    } else if (arg.startsWith('--api-key=')) {
      apiKey = arg.split('=').sublist(1).join('=');
    } else if (arg.startsWith('--output=')) {
      output = arg.split('=').sublist(1).join('=');
    } else if (arg.startsWith('--app-name=')) {
      appName = arg.split('=').sublist(1).join('=');
    } else if (arg.startsWith('--model=')) {
      model = arg.split('=').sublist(1).join('=');
    } else if (arg.startsWith('--env=')) {
      envFile = arg.split('=').sublist(1).join('=');
    } else if (arg == '--help' || arg == '-h') {
      _printUsage();
      exit(0);
    }
  }

  // Try loading API key from env file.
  if (apiKey == null && envFile != null) {
    apiKey = _loadApiKeyFromEnv(envFile);
  }

  // Auto-detect files if not specified.
  routesFile ??= _autoDetect('lib/models/routes.dart', 'lib/routes.dart');
  routerFile ??= _autoDetect('lib/app/router.dart', 'lib/router.dart');

  if (routesFile == null) {
    print('ERROR: Cannot find routes file. Specify with --routes-file=');
    exit(1);
  }
  if (routerFile == null) {
    print('ERROR: Cannot find router file. Specify with --router-file=');
    exit(1);
  }
  if (apiKey == null || apiKey.isEmpty) {
    print(
      'ERROR: Gemini API key required. Use --api-key= or --env=.env.staging',
    );
    exit(1);
  }

  return _Config(
    routesFile: routesFile,
    routerFile: routerFile,
    routesClass: routesClass,
    routesFileImport: routesFileImport,
    apiKey: apiKey,
    output: output,
    appName: appName,
    model: model,
  );
}

String? _autoDetect(String primary, String fallback) {
  if (File(primary).existsSync()) return primary;
  if (File(fallback).existsSync()) return fallback;
  return null;
}

String? _loadApiKeyFromEnv(String envFile) {
  final file = File(envFile);
  if (!file.existsSync()) {
    print('WARNING: env file $envFile not found');
    return null;
  }
  for (final line in file.readAsLinesSync()) {
    final trimmed = line.trim();
    if (trimmed.startsWith('GEMINI_API_KEY=')) {
      return trimmed.substring('GEMINI_API_KEY='.length).trim();
    }
  }
  return null;
}

void _printUsage() {
  print('''
flutter_ai_assistant: generate - LLM-powered app context manifest generator

Usage:
  dart run flutter_ai_assistant:generate [options]

Options:
  --routes-file=PATH     Path to routes file (default: auto-detect)
  --router-file=PATH     Path to router file (default: auto-detect)
  --routes-class=NAME    Route constants class name (default: Routes)
  --routes-import=PATH   Import path for routes in generated file (default: models/routes.dart)
  --api-key=KEY          Gemini API key
  --env=PATH             Load API key from .env file
  --output=PATH          Output file path (default: lib/ai_app_manifest.g.dart)
  --app-name=NAME        App name for the manifest (default: App)
  --model=NAME           Gemini model to use (default: gemini-2.0-flash)
  --help, -h             Show this help message
''');
}

// ---------------------------------------------------------------------------
// Source parsing
// ---------------------------------------------------------------------------

/// Parse route constants from the Routes class.
/// Returns {constantName: routeValue} e.g., {"walletScreen": "/wallet"}
Map<String, String> _parseRoutesFile(String path, String className) {
  final content = File(path).readAsStringSync();
  final pattern = RegExp(r'''static\s+const\s+(\w+)\s*=\s*['"]([^'"]+)['"]''');
  final matches = pattern.allMatches(content);
  return {for (final m in matches) m.group(1)!: m.group(2)!};
}

/// Parse the router file to map route constants to view class names.
/// Returns {routeConstantName: ViewClassName}
Map<String, String> _parseRouterFile(String path, String routesClass) {
  final content = File(path).readAsStringSync();
  // Match RouteDef(Routes.xxx, page: ClassName) — handles multiline.
  final pattern = RegExp(
    'RouteDef\\s*\\(\\s*$routesClass\\.(\\w+)\\s*,\\s*page:\\s*(\\w+)',
  );
  final matches = pattern.allMatches(content);
  return {for (final m in matches) m.group(1)!: m.group(2)!};
}

/// Find the lib/ directory from a file inside it.
String _findLibDir(String filePath) {
  var dir = File(filePath).parent;
  while (dir.path.contains('lib')) {
    if (dir.path.endsWith('lib') ||
        dir.path.endsWith('lib/') ||
        dir.path.endsWith('lib\\')) {
      return dir.path;
    }
    dir = dir.parent;
  }
  // Fallback: assume lib/ is relative to CWD.
  return 'lib';
}

/// Find the source file containing a class definition.
/// Returns the full source code or null if not found.
String? _findClassSource(String libDir, String className) {
  final dir = Directory(libDir);
  if (!dir.existsSync()) return null;

  for (final entity in dir.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      final content = entity.readAsStringSync();
      if (RegExp('class\\s+$className\\s').hasMatch(content)) {
        // Normalize Windows line endings.
        var normalized = content
            .replaceAll('\r\n', '\n')
            .replaceAll('\r', '\n');
        // Truncate very large files to stay within LLM token limits.
        if (normalized.length > 12000) {
          normalized = '${normalized.substring(0, 12000)}\n// ... (truncated)';
        }
        return normalized;
      }
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Gemini API
// ---------------------------------------------------------------------------

/// Send a screen's source code to Gemini for analysis.
Future<Map<String, dynamic>?> _analyzeScreen(
  String apiKey,
  String routeConstant,
  String routeValue,
  String sourceCode,
  String model,
) async {
  final prompt =
      '''
Analyze this Flutter screen widget source code and return a JSON object describing the screen for an AI navigation agent.

Route constant: $routeConstant
Route value: $routeValue

```dart
$sourceCode
```

Return ONLY valid JSON (no markdown fencing, no explanation) with this exact structure:
{
  "title": "short screen title (2-4 words)",
  "description": "1-3 sentence description of what this screen shows and what the user can do here",
  "sections": [
    {
      "title": "visible section heading or logical group name",
      "description": "what this section shows",
      "elements": [
        {"label": "visible text label of the element", "type": "button|textField|toggle|list|card|text|image", "behavior": "what happens when interacted with"}
      ]
    }
  ],
  "actions": [
    {"name": "action name", "howTo": "how to perform this action on this screen", "isDestructive": false}
  ],
  "navigatesTo": [
    {"route": "/targetRouteValue", "trigger": "what triggers this navigation (e.g. tap which button)"}
  ],
  "notes": ["any important caveats like 'requires login' or 'only visible to drivers'"]
}

Rules:
- Focus on user-facing elements, not internal implementation details.
- For "label", use the EXACT text the user would see on screen.
- For "navigatesTo", use the route VALUE (e.g., "/wallet"), not the constant name.
- Only include elements that are meaningful for navigation/interaction.
- Keep descriptions concise but informative.
- If you cannot determine something from the source, make a reasonable inference.
''';

  final response = await _callGemini(apiKey, prompt, model);
  if (response == null) return null;

  try {
    return jsonDecode(response) as Map<String, dynamic>;
  } catch (e) {
    // Try to extract JSON from markdown fencing.
    final jsonMatch = RegExp(
      r'```(?:json)?\s*([\s\S]*?)\s*```',
    ).firstMatch(response);
    if (jsonMatch != null) {
      return jsonDecode(jsonMatch.group(1)!) as Map<String, dynamic>;
    }
    print('    WARNING: Failed to parse JSON response: $e');
    return null;
  }
}

/// Generate common multi-screen flows from all screen analyses.
Future<List<Map<String, dynamic>>> _generateFlows(
  String apiKey,
  Map<String, String> routeConstants,
  Map<String, Map<String, dynamic>> screenAnalyses,
  String model,
) async {
  final screenSummaries = StringBuffer();
  for (final entry in screenAnalyses.entries) {
    final routeValue = routeConstants[entry.key] ?? '/${entry.key}';
    final analysis = entry.value;
    screenSummaries.writeln(
      '$routeValue (${entry.key}): ${analysis['title']} — ${analysis['description']}',
    );
    final navLinks = analysis['navigatesTo'] as List<dynamic>?;
    if (navLinks != null && navLinks.isNotEmpty) {
      for (final link in navLinks) {
        screenSummaries.writeln('  -> ${link['route']} via ${link['trigger']}');
      }
    }
  }

  final prompt =
      '''
Given these app screens and their navigation links, identify the 3-5 most important multi-step user journeys (flows) that span multiple screens.

SCREENS:
$screenSummaries

Return ONLY valid JSON (no markdown fencing) as an array:
[
  {
    "name": "flow name (e.g., 'Book a ride')",
    "description": "one-line description of the complete flow",
    "steps": [
      {"route": "/routeValue", "instruction": "what the user does on this screen", "expectedOutcome": "what happens after (optional, null if not final step)"}
    ]
  }
]

Rules:
- Each flow should span at least 2 screens.
- Use route VALUES (e.g., "/wallet"), not constant names.
- Steps should be in order from start to finish.
- Focus on the most common user tasks.
- Keep instructions concise and actionable.
''';

  final response = await _callGemini(apiKey, prompt, model);
  if (response == null) return [];

  try {
    final parsed = jsonDecode(response);
    if (parsed is List) {
      return parsed.cast<Map<String, dynamic>>();
    }
    return [];
  } catch (e) {
    final jsonMatch = RegExp(
      r'```(?:json)?\s*([\s\S]*?)\s*```',
    ).firstMatch(response);
    if (jsonMatch != null) {
      final parsed = jsonDecode(jsonMatch.group(1)!);
      if (parsed is List) return parsed.cast<Map<String, dynamic>>();
    }
    return [];
  }
}

/// Call Gemini API and return the text response.
Future<String?> _callGemini(String apiKey, String prompt, String model) async {
  final url = Uri.parse(
    'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey',
  );

  final client = HttpClient();
  try {
    final request = await client.postUrl(url);
    request.headers.set('Content-Type', 'application/json; charset=utf-8');
    request.add(
      utf8.encode(
        jsonEncode({
          'contents': [
            {
              'parts': [
                {'text': prompt},
              ],
            },
          ],
          'generationConfig': {'temperature': 0.1, 'maxOutputTokens': 4096},
        }),
      ),
    );

    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();

    if (response.statusCode != 200) {
      print('    Gemini API error (${response.statusCode}): $body');
      return null;
    }

    final json = jsonDecode(body) as Map<String, dynamic>;
    final candidates = json['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) return null;

    final content = candidates[0]['content'] as Map<String, dynamic>?;
    final parts = content?['parts'] as List<dynamic>?;
    if (parts == null || parts.isEmpty) return null;

    return parts[0]['text'] as String?;
  } finally {
    client.close();
  }
}

// ---------------------------------------------------------------------------
// Dart code generation
// ---------------------------------------------------------------------------

String _generateDartFile({
  required Map<String, String> routeConstants,
  required String routesClass,
  required String routesFileImport,
  required Map<String, Map<String, dynamic>> screenAnalyses,
  required List<Map<String, dynamic>> flows,
  required String appName,
}) {
  // Initialize reverse route map for resolving route values to constants.
  _reverseRouteMap = {
    for (final entry in routeConstants.entries) entry.value: entry.key,
  };

  final buffer = StringBuffer();

  // Header.
  final timestamp = DateTime.now().toUtc().toIso8601String();
  buffer.writeln('// GENERATED by flutter_ai_assistant ($timestamp)');
  buffer.writeln(
    '// To regenerate: dart run flutter_ai_assistant:generate --env=.env.staging',
  );
  buffer.writeln(
    '// Developer edits are welcome — re-generation only appends new routes.',
  );
  buffer.writeln('');
  buffer.writeln(
    "import 'package:flutter_ai_assistant/flutter_ai_assistant.dart';",
  );
  buffer.writeln("import '$routesFileImport';");
  buffer.writeln('');

  // Build app description from screen analyses.
  final screenTitles = screenAnalyses.values
      .map((a) => a['title'] as String? ?? '')
      .where((t) => t.isNotEmpty)
      .take(6)
      .join(', ');

  buffer.writeln('const aiAppManifest = AiAppManifest(');
  buffer.writeln("  appName: ${_dartString(appName)},");
  buffer.writeln(
    "  appDescription: ${_dartString('$appName is a mobile app with screens including: $screenTitles.')},",
  );
  buffer.writeln('  screens: {');

  // Generate screen entries.
  for (final entry in screenAnalyses.entries) {
    final routeConstant = entry.key;
    final analysis = entry.value;
    _writeScreenManifest(buffer, routeConstant, routesClass, analysis);
  }

  // Add stub entries for routes that were in the router but couldn't be analyzed.
  for (final routeConstant in routeConstants.keys) {
    if (!screenAnalyses.containsKey(routeConstant)) {
      final title = _inferTitle(routeConstant);
      buffer.writeln('    $routesClass.$routeConstant: AiScreenManifest(');
      buffer.writeln('      route: $routesClass.$routeConstant,');
      buffer.writeln('      title: ${_dartString(title)},');
      buffer.writeln("      description: ${_dartString('$title screen.')},");
      buffer.writeln('    ),');
    }
  }

  buffer.writeln('  },');

  // Flows.
  if (flows.isNotEmpty) {
    buffer.writeln('  flows: [');
    for (final flow in flows) {
      _writeFlowManifest(buffer, flow, routeConstants, routesClass);
    }
    buffer.writeln('  ],');
  }

  buffer.writeln(');');

  return buffer.toString();
}

void _writeScreenManifest(
  StringBuffer buffer,
  String routeConstant,
  String routesClass,
  Map<String, dynamic> analysis,
) {
  final title = analysis['title'] as String? ?? _inferTitle(routeConstant);
  final description = analysis['description'] as String? ?? '$title screen.';
  final sections = analysis['sections'] as List<dynamic>? ?? [];
  final actions = analysis['actions'] as List<dynamic>? ?? [];
  final navigatesTo = analysis['navigatesTo'] as List<dynamic>? ?? [];
  final notes = analysis['notes'] as List<dynamic>? ?? [];

  buffer.writeln('    $routesClass.$routeConstant: AiScreenManifest(');
  buffer.writeln('      route: $routesClass.$routeConstant,');
  buffer.writeln('      title: ${_dartString(title)},');
  buffer.writeln('      description: ${_dartString(description)},');

  // Sections.
  if (sections.isNotEmpty) {
    buffer.writeln('      sections: [');
    for (final section in sections) {
      final sTitle = section['title'] as String? ?? '';
      final sDesc = section['description'] as String? ?? '';
      final elements = section['elements'] as List<dynamic>? ?? [];

      buffer.writeln('        AiSectionManifest(');
      buffer.writeln('          title: ${_dartString(sTitle)},');
      buffer.writeln('          description: ${_dartString(sDesc)},');
      if (elements.isNotEmpty) {
        buffer.writeln('          elements: [');
        for (final elem in elements) {
          final label = elem['label'] as String? ?? '';
          final type = elem['type'] as String? ?? 'text';
          final behavior = elem['behavior'] as String?;
          buffer.write('            AiElementManifest(');
          buffer.write('label: ${_dartString(label)}, ');
          buffer.write('type: ${_dartString(type)}');
          if (behavior != null && behavior.isNotEmpty) {
            buffer.write(', behaviorDescription: ${_dartString(behavior)}');
          }
          buffer.writeln('),');
        }
        buffer.writeln('          ],');
      }
      buffer.writeln('        ),');
    }
    buffer.writeln('      ],');
  }

  // Actions.
  if (actions.isNotEmpty) {
    buffer.writeln('      actions: [');
    for (final action in actions) {
      final name = action['name'] as String? ?? '';
      final howTo = action['howTo'] as String? ?? '';
      final isDestructive = action['isDestructive'] as bool? ?? false;
      buffer.write('        AiActionManifest(');
      buffer.write('name: ${_dartString(name)}, ');
      buffer.write('howTo: ${_dartString(howTo)}');
      if (isDestructive) buffer.write(', isDestructive: true');
      buffer.writeln('),');
    }
    buffer.writeln('      ],');
  }

  // Navigation links.
  if (navigatesTo.isNotEmpty) {
    buffer.writeln('      linksTo: [');
    for (final link in navigatesTo) {
      final route = link['route'] as String? ?? '';
      final trigger = link['trigger'] as String? ?? '';
      // Try to resolve route value to a Routes constant.
      final routeRef = _resolveRouteRef(route, routesClass);
      buffer.writeln(
        '        AiNavigationLink(targetRoute: $routeRef, trigger: ${_dartString(trigger)}),',
      );
    }
    buffer.writeln('      ],');
  }

  // Notes.
  if (notes.isNotEmpty) {
    buffer.writeln('      notes: [');
    for (final note in notes) {
      buffer.writeln('        ${_dartString(note as String)},');
    }
    buffer.writeln('      ],');
  }

  buffer.writeln('    ),');
}

void _writeFlowManifest(
  StringBuffer buffer,
  Map<String, dynamic> flow,
  Map<String, String> routeConstants,
  String routesClass,
) {
  final name = flow['name'] as String? ?? 'Untitled Flow';
  final description = flow['description'] as String? ?? '';
  final steps = flow['steps'] as List<dynamic>? ?? [];

  buffer.writeln('    AiFlowManifest(');
  buffer.writeln('      name: ${_dartString(name)},');
  buffer.writeln('      description: ${_dartString(description)},');
  buffer.writeln('      steps: [');
  for (final step in steps) {
    final route = step['route'] as String? ?? '';
    final instruction = step['instruction'] as String? ?? '';
    final expectedOutcome = step['expectedOutcome'] as String?;
    final routeRef = _resolveRouteRef(route, routesClass);
    buffer.write(
      '        AiFlowStep(route: $routeRef, instruction: ${_dartString(instruction)}',
    );
    if (expectedOutcome != null && expectedOutcome.isNotEmpty) {
      buffer.write(', expectedOutcome: ${_dartString(expectedOutcome)}');
    }
    buffer.writeln('),');
  }
  buffer.writeln('      ],');
  buffer.writeln('    ),');
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// A static reverse map built once during generation.
/// Maps route values to their constant names.
Map<String, String>? _reverseRouteMap;

/// Resolve a route value (e.g., "/wallet") to a Routes class reference.
/// Falls back to a string literal if no constant is found.
String _resolveRouteRef(String routeValue, String routesClass) {
  if (_reverseRouteMap == null) {
    // Will be initialized by the caller context — use string literal fallback.
    return _dartString(routeValue);
  }
  final constantName = _reverseRouteMap![routeValue];
  if (constantName != null) {
    return '$routesClass.$constantName';
  }
  return _dartString(routeValue);
}

/// Infer a human-readable title from a route constant name.
/// e.g., "riderHomeScreen" → "Rider Home"
String _inferTitle(String constantName) {
  // Remove common suffixes.
  var name = constantName;
  for (final suffix in ['Screen', 'View', 'Page']) {
    if (name.endsWith(suffix) && name.length > suffix.length) {
      name = name.substring(0, name.length - suffix.length);
    }
  }

  // Split camelCase.
  final words = name.replaceAllMapped(
    RegExp(r'([a-z])([A-Z])'),
    (m) => '${m.group(1)} ${m.group(2)}',
  );

  // Capitalize first letter.
  if (words.isEmpty) return constantName;
  return words[0].toUpperCase() + words.substring(1);
}

/// Escape a string for use as a Dart string literal.
String _dartString(String value) {
  final escaped = value
      .replaceAll('\\', '\\\\')
      .replaceAll("'", "\\'")
      .replaceAll('\n', '\\n')
      .replaceAll('\r', '');
  return "'$escaped'";
}
