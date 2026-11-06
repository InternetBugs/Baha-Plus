/// Request a desktop Chromium page using the installed engine's real version.
/// The plugin's Android desktop mode otherwise leaves WebView/mobile markers
/// which can make the official site continue serving its mobile landing page.
String desktopChromiumUserAgent(String nativeAgent) => nativeAgent
    .replaceFirst(RegExp(r'\([^)]*\)'), '(X11; Linux x86_64)')
    .replaceAll(RegExp(r'\b(?:Version/\S+|Mobile(?:/\S+)?)\s*'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
