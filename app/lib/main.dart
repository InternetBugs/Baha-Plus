import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'data/app_store.dart';
import 'data/app_diagnostics.dart';
import 'data/official_user_agent.dart';
import 'data/system_http.dart';
import 'ui/app_root.dart';
import 'ui/chrome.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final diagnostics = AppDiagnostics.instance;
  diagnostics.installErrorHooks();
  try {
    await diagnostics.initialize();
    diagnostics.record('app.started');
  } catch (_) {
    // A full or unavailable diagnostics directory must not prevent startup.
  }
  HttpOverrides.global = SystemHttpOverrides();
  await OfficialUserAgent.resolve();
  await LiquidGlassWidgets.initialize(enablePerformanceMonitor: false);
  final store = await AppStore.create();
  runApp(
    LiquidGlassWidgets.wrap(
      brightnessResolver: Theme.maybeBrightnessOf,
      theme: const GlassThemeData.ios27(),
      child: BahaPlusApp(store: store),
    ),
  );
}

class BahaPlusApp extends StatefulWidget {
  const BahaPlusApp({required this.store, this.mountPortal = true, super.key});
  final AppStore store;
  final bool mountPortal;

  @override
  State<BahaPlusApp> createState() => _BahaPlusAppState();
}

class _BahaPlusAppState extends State<BahaPlusApp> {
  AppStore get store => widget.store;
  late String _language, _appearance, _glassStyle;

  @override
  void initState() {
    super.initState();
    _observePreferences();
  }

  void _observePreferences() {
    _language = store.language;
    _appearance = store.appearance;
    _glassStyle = store.glassStyle;
    store.addListener(_preferencesChanged);
  }

  void _preferencesChanged() {
    if (_language == store.language &&
        _appearance == store.appearance &&
        _glassStyle == store.glassStyle) {
      return;
    }
    setState(() {
      _language = store.language;
      _appearance = store.appearance;
      _glassStyle = store.glassStyle;
    });
  }

  @override
  void didUpdateWidget(covariant BahaPlusApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != store) {
      oldWidget.store.removeListener(_preferencesChanged);
      _observePreferences();
    }
  }

  @override
  void dispose() {
    store.removeListener(_preferencesChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Baha Plus',
    debugShowCheckedModeBanner: false,
    locale: Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: store.simplified ? 'Hans' : 'Hant',
    ),
    supportedLocales: const [
      Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
      Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
    ],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    themeMode: switch (store.appearance) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    },
    builder: (context, child) {
      final theme = Theme.of(context);
      final text = TextStyle(
        fontFamily: 'BahaSans',
        fontFamilyFallback: const ['BahaSansSC'],
        fontSize: 16,
        color: theme.colorScheme.onSurface,
        decoration: TextDecoration.none,
      );
      return DefaultTextStyle(
        style: text,
        child: CupertinoTheme(
          data: CupertinoThemeData(
            brightness: theme.brightness,
            primaryColor: brandBlue,
            scaffoldBackgroundColor: theme.scaffoldBackgroundColor,
            textTheme: CupertinoTextThemeData(
              textStyle: text,
              actionTextStyle: text.copyWith(color: brandBlue),
              navActionTextStyle: text.copyWith(color: brandBlue),
              navTitleTextStyle: text.copyWith(
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
              navLargeTitleTextStyle: text.copyWith(
                fontSize: 34,
                fontWeight: FontWeight.w700,
              ),
              tabLabelTextStyle: text.copyWith(fontSize: 11),
            ),
          ),
          child: GlassTheme(
            data: _glassTheme(),
            child: Stack(
              children: [
                child ?? const SizedBox.shrink(),
                if (child != null)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: GlassNoticeToast(store: store),
                  ),
              ],
            ),
          ),
        ),
      );
    },
    home: AppRoot(store: store, mountPortal: widget.mountPortal),
  );

  /// Glass tier chosen by the user in the settings; see [AppStore.glassStyle].
  GlassThemeData _glassTheme() {
    final quality = switch (_glassStyle) {
      'performance' => GlassQuality.minimal,
      'premium' => GlassQuality.premium,
      _ => GlassQuality.standard,
    };
    return GlassThemeData(
      light: GlassThemeVariant.ios27Light.copyWith(quality: quality),
      dark: GlassThemeVariant.ios27Dark.copyWith(quality: quality),
    );
  }

  ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: brandBlue,
      brightness: brightness,
      surface: dark ? const Color(0xff1c1c1e) : Colors.white,
      surfaceContainerLowest: dark
          ? const Color(0xff000000)
          : const Color(0xfff2f2f7),
    );
    return ThemeData(
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: 'BahaSans',
      scaffoldBackgroundColor: dark ? const Color(0xff08080a) : Colors.white,
      useMaterial3: true,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      textTheme: ThemeData(
        brightness: brightness,
      ).textTheme.apply(fontFamily: 'BahaSans'),
    );
  }
}
