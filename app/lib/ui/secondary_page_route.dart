import 'package:flutter/cupertino.dart';

/// Keep an active platform video view in the compositor beneath a secondary
/// page. Retaining its Dart state alone still lets opaque routes hide WKWebView.
class SecondaryPageRoute<T> extends PageRoute<T>
    with CupertinoRouteTransitionMixin<T> {
  SecondaryPageRoute({
    required this.builder,
    required this.keepsPlaybackVisible,
  }) : super(fullscreenDialog: true, allowSnapshotting: !keepsPlaybackVisible);

  final WidgetBuilder builder;
  final bool keepsPlaybackVisible;

  @override
  bool get opaque => !keepsPlaybackVisible;

  @override
  bool get maintainState => true;

  @override
  String? get title => null;

  @override
  Widget buildContent(BuildContext context) => builder(context);
}
