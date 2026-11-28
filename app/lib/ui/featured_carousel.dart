import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'chrome.dart';

class FeaturedCarousel<T> extends StatefulWidget {
  const FeaturedCarousel({
    required this.items,
    required this.keyIdOf,
    required this.itemBuilder,
    super.key,
  });

  final List<T> items;
  final String Function(T) keyIdOf;
  final Widget Function(BuildContext, T) itemBuilder;

  @override
  State<FeaturedCarousel<T>> createState() => _FeaturedCarouselState<T>();
}

class _FeaturedCarouselState<T> extends State<FeaturedCarousel<T>> {
  final ValueNotifier<int> _currentPage = ValueNotifier<int>(0);
  PageController? _pages;
  double _fraction = .96;

  @override
  void initState() {
    super.initState();
    _syncRestoredPageAfterFrame();
  }

  @override
  void didUpdateWidget(covariant FeaturedCarousel<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final maxIndex = math.max(0, widget.items.length - 1);
    if (_currentPage.value > maxIndex) {
      _currentPage.value = maxIndex;
    }
  }

  void _syncRestoredPageAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = _pages;
      if (controller == null || !controller.hasClients) return;
      final restored = controller.page?.round();
      if (restored == null) return;
      final clamped = restored
          .clamp(0, math.max(0, widget.items.length - 1))
          .toInt();
      if (_currentPage.value != clamped) _currentPage.value = clamped;
    });
  }

  PageController _controllerFor(double fraction) {
    if (_pages != null && (_fraction - fraction).abs() < .01) {
      return _pages!;
    }
    final initialPage = _pages != null && _pages!.hasClients
        ? (_pages!.page?.round() ?? _pages!.initialPage)
        : _currentPage.value;
    final previous = _pages;
    _fraction = fraction;
    final clamped = initialPage
        .clamp(0, math.max(0, widget.items.length - 1))
        .toInt();
    _pages = PageController(initialPage: clamped, viewportFraction: fraction);
    // Defer notifier mutation and disposal past layout/build to avoid
    // triggering setState/markNeedsBuild inside LayoutBuilder.
    if (_currentPage.value != clamped) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _currentPage.value != clamped) {
          _currentPage.value = clamped;
        }
      });
    }
    if (previous != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
    }
    return _pages!;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final wide = bounds.maxWidth >= 560;
      final singleWide = wide && widget.items.length == 1;
      final reduceMotion = MediaQuery.disableAnimationsOf(context);
      final textScaler = MediaQuery.textScalerOf(context);
      final extraTextHeight = math.max(0.0, textScaler.scale(16) - 16) * 4.5;
      final double fraction;
      final double height;
      final int visibleCount;
      if (!wide) {
        fraction = .95;
        height = math.min(bounds.maxWidth * 1.06 + extraTextHeight, 440.0);
        visibleCount = 1;
      } else if (singleWide) {
        fraction = 1.0;
        height = math.min(bounds.maxWidth * .50 + extraTextHeight, 440.0);
        visibleCount = 1;
      } else if (bounds.maxWidth >= 960) {
        visibleCount = math.min(3, widget.items.length);
        fraction = (bounds.maxWidth + 16.0) / (visibleCount * bounds.maxWidth);
        final cardWidth = bounds.maxWidth * fraction - 16.0;
        height = math.min(cardWidth * 1.18 + extraTextHeight, 460.0);
      } else {
        const targetCardWidth = 350.0;
        fraction = (targetCardWidth / bounds.maxWidth).clamp(.42, .54);
        height = math.min(targetCardWidth * 1.18 + extraTextHeight, 460.0);
        visibleCount = (1 / fraction).floor().clamp(1, widget.items.length);
      }
      final controller = _controllerFor(fraction);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: height,
            child: PageView.builder(
              key: const PageStorageKey('featured-carousel-pages'),
              controller: controller,
              clipBehavior: Clip.none,
              padEnds: false,
              allowImplicitScrolling: true,
              physics: const BouncingScrollPhysics(),
              itemCount: widget.items.length,
              onPageChanged: (index) => _currentPage.value = index,
              itemBuilder: (context, index) => Padding(
                key: ValueKey('featured-${widget.keyIdOf(widget.items[index])}'),
                padding: EdgeInsets.only(
                  right: singleWide ? 0 : (wide ? 16 : 12),
                ),
                child: widget.itemBuilder(context, widget.items[index]),
              ),
            ),
          ),
          if (widget.items.length > visibleCount) ...[
            const SizedBox(height: 12),
            ValueListenableBuilder<int>(
              valueListenable: _currentPage,
              builder: (context, page, _) {
                final activeIndex = page
                    .clamp(0, math.max(0, widget.items.length - 1))
                    .toInt();
                return Row(
                  key: const ValueKey('featured-carousel-indicators'),
                  children: [
                    for (
                      var index = 0;
                      index < widget.items.length;
                      index++
                    ) ...[
                      if (index > 0) const SizedBox(width: 6),
                      AnimatedContainer(
                        duration: reduceMotion
                            ? Duration.zero
                            : const Duration(milliseconds: 200),
                        curve: Curves.easeOutCubic,
                        width: index == activeIndex ? 20 : 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: index == activeIndex
                              ? brandBlue
                              : secondary(context).withValues(alpha: .32),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ],
        ],
      );
    },
  );

  @override
  void dispose() {
    _currentPage.dispose();
    _pages?.dispose();
    super.dispose();
  }
}
