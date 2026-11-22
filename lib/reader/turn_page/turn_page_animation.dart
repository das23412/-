// 基于 turn_page_transition v0.5.0 (MIT License) 修改
// Copyright (c) 2022 Shoryu-Y — https://github.com/Shoryu-Y/turn_page_transition
// 修改内容：折缝处增加柔和投影，使卷页更接近实体书效果。

import 'package:flutter/material.dart';
import 'package:moyue/reader/turn_page/turn_page_const.dart';
import 'package:moyue/reader/turn_page/turn_direction.dart';

/// A widget that provides a page-turning animation.
class TurnPageAnimation extends StatelessWidget {
  TurnPageAnimation({
    super.key,
    required this.animation,
    required this.overleafColor,
    required this.overleafBorderColor,
    required this.overleafBorderWidth,
    this.animationTransitionPoint,
    this.direction = TurnDirection.rightToLeft,
    required this.child,
  }) {
    final transitionPoint = animationTransitionPoint;
    assert(
      transitionPoint == null || 0 <= transitionPoint && transitionPoint < 1,
      'animationTransitionPoint must be 0 <= animationTransitionPoint < 1',
    );
  }

  /// The animation that controls the page-turning effect.
  final Animation<double> animation;

  /// The color of the backside of the pages.
  /// Default color is [Colors.grey].
  final Color overleafColor;

  /// The color of the overleaf border that appears on the page edge during transition
  final Color overleafBorderColor;

  /// The width of the overleaf border that appears on the page edge during transition
  final double overleafBorderWidth;

  /// The point that behavior of the turn-page-animation changes.
  /// This value must be 0 <= animationTransitionPoint < 1.
  final double? animationTransitionPoint;

  /// The direction in which the pages are turned.
  final TurnDirection direction;

  /// The widget that is displayed with the page-turning animation.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final transitionPoint =
        animationTransitionPoint ?? defaultAnimationTransitionPoint;

    final alignment = direction == TurnDirection.rightToLeft
        ? Alignment.centerLeft
        : Alignment.centerRight;

    return CustomPaint(
      foregroundPainter: _OverleafPainter(
        animation: animation,
        color: overleafColor,
        overleafBorderColor: overleafBorderColor,
        overleafBorderWidth: overleafBorderWidth,
        animationTransitionPoint: transitionPoint,
        direction: direction,
      ),
      child: Align(
        alignment: alignment,
        child: ClipPath(
          clipper: _PageTurnClipper(
            animation: animation,
            animationTransitionPoint: transitionPoint,
            direction: direction,
          ),
          child: Align(
            alignment: alignment,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// CustomClipper that creates the page-turning clipping path.
class _PageTurnClipper extends CustomClipper<Path> {
  _PageTurnClipper({
    required Animation<double> animation,
    required this.animationTransitionPoint,
    this.direction = TurnDirection.leftToRight,
  })  : animation = animation;

  // 逐帧重裁由 shouldReclip 的「上次裁剪值快照」驱动（见 _clippedAt）：
  // AnimatedBuilder 每帧重建都会拿到新 clipper 实例，快照值不同即返回 true。

  /// The animation that controls the page-turning effect.
  final Animation<double> animation;

  /// The point at which the page-turning animation behavior changes.
  /// This value must be between 0 and 1 (0 <= animationTransitionPoint < 1).
  final double animationTransitionPoint;

  /// The direction in which the pages are turned.
  final TurnDirection direction;

  /// 上一次实际执行 getClip 时的动画进度快照：同一 Animation 对象被新旧
  /// 实例共享，直接比 value 恒等会冻结翻页；快照在 getClip 时写入，
  /// 旧实例的快照是上一帧的值，与新实例的当前值在动画中必然不同。
  double? _clippedAt;

  /// Creates the clipping path based on the animation progress and direction.
  @override
  Path getClip(Size size) {
    final width = size.width;
    final height = size.height;
    final animationProgress = animation.value;

    // 记录本次实际裁剪用的进度，供 shouldReclip 与旧实例比较
    _clippedAt = animationProgress;

    final verticalVelocity = 1 / animationTransitionPoint;

    late final double innerTopCornerX;
    late final double innerBottomCornerX;
    late final double outerBottomCornerX;
    late final double foldUpperCornerX;
    late final double foldLowerCornerX;
    switch (direction) {
      case TurnDirection.rightToLeft:
        innerTopCornerX = 0.0;
        innerBottomCornerX = 0.0;
        foldUpperCornerX = width * (1.0 - animationProgress);
        break;
      case TurnDirection.leftToRight:
        innerTopCornerX = width;
        innerBottomCornerX = width;
        foldUpperCornerX = width * animationProgress;
        break;
    }

    final innerTopCorner = Offset(innerTopCornerX, 0.0);
    final foldUpperCorner = Offset(foldUpperCornerX, 0.0);
    final innerBottomCorner = Offset(innerBottomCornerX, height);

    final path = Path()
      ..moveTo(innerTopCorner.dx, innerTopCorner.dy)
      ..lineTo(foldUpperCorner.dx, foldUpperCorner.dy);

    if (animationProgress <= animationTransitionPoint) {
      final foldLowerCornerY = height * verticalVelocity * animationProgress;
      switch (direction) {
        case TurnDirection.rightToLeft:
          outerBottomCornerX = width;
          foldLowerCornerX = width;
          break;
        case TurnDirection.leftToRight:
          outerBottomCornerX = 0.0;
          foldLowerCornerX = 0.0;
          break;
      }
      final outerBottomCorner = Offset(outerBottomCornerX, height);
      final foldLowerCorner = Offset(foldLowerCornerX, foldLowerCornerY);
      path
        ..lineTo(foldLowerCorner.dx, foldLowerCorner.dy)
        ..lineTo(outerBottomCorner.dx, outerBottomCorner.dy)
        ..lineTo(innerBottomCorner.dx, innerBottomCorner.dy)
        ..close();
    } else {
      final progressSubtractedDefault =
          animationProgress - animationTransitionPoint;
      final horizontalVelocity = 1 / (1 - animationTransitionPoint);
      final turnedBottomWidth =
          width * progressSubtractedDefault * horizontalVelocity;

      switch (direction) {
        case TurnDirection.rightToLeft:
          foldLowerCornerX = width - turnedBottomWidth;
          break;
        case TurnDirection.leftToRight:
          foldLowerCornerX = turnedBottomWidth;
          break;
      }

      final foldLowerCorner = Offset(foldLowerCornerX, height);

      path
        ..lineTo(foldLowerCorner.dx, foldLowerCorner.dy) // BottomLeft
        ..lineTo(innerBottomCorner.dx, innerBottomCorner.dy) // BottomRight
        ..close();
    }

    return path;
  }

  @override
  bool shouldReclip(_PageTurnClipper oldClipper) {
    // 快照值不同（任一帧进度推进）即重裁；静态参数变化也重裁。
    return oldClipper._clippedAt != animation.value ||
        oldClipper.animation != animation ||
        oldClipper.animationTransitionPoint != animationTransitionPoint ||
        oldClipper.direction != direction;
  }
}

/// CustomPainter that paints the backside of the pages during the animation.
class _OverleafPainter extends CustomPainter {
  _OverleafPainter({
    required Animation<double> animation,
    required this.color,
    required this.overleafBorderColor,
    required this.overleafBorderWidth,
    required this.animationTransitionPoint,
    required this.direction,
  })  : animation = animation,
        // 进度重绘由 animation 直接驱动（每帧 markNeedsPaint）。
        super(repaint: animation);

  /// The animation that controls the page-turning effect.
  final Animation<double> animation;

  /// The color of the backside of the pages.
  final Color color;

  /// The color of the overleaf border that appears on the page edge during transition
  final Color overleafBorderColor;

  /// The width of the overleaf border that appears on the page edge during transition
  final double overleafBorderWidth;

  /// The point at which the page-turning animation behavior changes.
  /// This value must be between 0 and 1 (0 <= animationTransitionPoint < 1).
  final double animationTransitionPoint;

  /// The direction in which the pages are turned.
  final TurnDirection direction;

  @override
  void paint(Canvas canvas, Size size) {
    final width = size.width;
    final height = size.height;
    final animationProgress = animation.value;

    // 进度为 0（未开始）或 ≥1（已完成）时没有可见的翻页叶子：直接返回，
    // 不再构造路径。进度恰为 0 时下方 W*H/(W²+H²) 会得到 0/0 = NaN，
    // 把 NaN 坐标画进路径行为未定义；提前返回也省掉阴影模糊/填充/描边开销。
    if (animationProgress <= 0 || animationProgress >= 1) {
      return;
    }

    late final double topCornerX;
    late final double bottomCornerX;
    late final double topFoldX;
    late final double bottomFoldX;

    final turnedXDistance = width * animationProgress;

    switch (direction) {
      case TurnDirection.rightToLeft:
        topFoldX = width - turnedXDistance;
        break;
      case TurnDirection.leftToRight:
        topFoldX = turnedXDistance;
        break;
    }
    final topFold = Offset(topFoldX, 0.0);

    final path = Path()..moveTo(topFold.dx, topFold.dy);

    if (animationProgress <= animationTransitionPoint) {
      final verticalVelocity = 1 / animationTransitionPoint;
      final turnedYDistance = height * animationProgress * verticalVelocity;

      final W = turnedXDistance;
      final H = turnedYDistance;
      // Intersection of the line connecting (W, 0) & (W, H) and perpendicular line.
      final intersectionX = (W * H * H) / (W * W + H * H);
      final intersectionY = (W * W * H) / (W * W + H * H);

      switch (direction) {
        case TurnDirection.rightToLeft:
          topCornerX = width - 2 * intersectionX;
          bottomFoldX = width;
          break;
        case TurnDirection.leftToRight:
          topCornerX = 2 * intersectionX;
          bottomFoldX = 0.0;
          break;
      }
      final topCorner = Offset(topCornerX, 2 * intersectionY);
      final bottomFold = Offset(bottomFoldX, turnedYDistance);

      path
        ..lineTo(topCorner.dx, topCorner.dy)
        ..lineTo(bottomFold.dx, bottomFold.dy)
        ..close();
    } else if (animationProgress < 1) {
      final horizontalVelocity = 1 / (1 - animationTransitionPoint);
      final progressSubtractedDefault =
          animationProgress - animationTransitionPoint;
      final turnedBottomWidthRate =
          horizontalVelocity * progressSubtractedDefault;

      // Alias that converts values to simple characters. -------
      final w2 = width * width;
      final h2 = height * height;
      final q = animationProgress - turnedBottomWidthRate;
      final q2 = q * q;

      // --------------------------------------------------------

      // Page corner position which is line target point of (W, 0) for the line connecting (W, 0) & (W, H).
      final intersectionX = width * h2 * animationProgress / (w2 * q2 + h2);
      final intersectionY =
          w2 * height * animationProgress * q / (w2 * q2 + h2);

      final intersectionCorrection =
          (animationProgress - q) / animationProgress;

      final turnedBottomWidth =
          width * progressSubtractedDefault * horizontalVelocity;

      switch (direction) {
        case TurnDirection.rightToLeft:
          topCornerX = width - 2 * intersectionX;
          bottomCornerX = width - 2 * intersectionX * intersectionCorrection;
          bottomFoldX = width - turnedBottomWidth;
          break;
        case TurnDirection.leftToRight:
          topCornerX = 2 * intersectionX;
          bottomCornerX = 2 * intersectionX * intersectionCorrection;
          bottomFoldX = turnedBottomWidth;
          break;
      }
      final topCorner = Offset(topCornerX, 2 * intersectionY);
      final bottomCorner = Offset(
        bottomCornerX,
        2 * intersectionY * intersectionCorrection + height,
      );
      final bottomFold = Offset(bottomFoldX, height);

      path
        ..lineTo(topCorner.dx, topCorner.dy)
        ..lineTo(bottomCorner.dx, bottomCorner.dy)
        ..lineTo(bottomFold.dx, bottomFold.dy)
        ..close();
    }
    // 进度 ≥1 已在 paint 开头提前返回，此处 progress < 1 恒成立。

    // 折缝投影：卷起的叶子在下方页面上的柔和阴影（向揭示侧偏移）
    final shadowShift = direction == TurnDirection.rightToLeft ? 16.0 : -16.0;
    final shadowPath = path.shift(Offset(shadowShift, 5.0));
    canvas.drawPath(
        shadowPath,
        Paint()
          ..color = Colors.black.withValues(alpha: 0.20)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9));

    final fillPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final linePaint = Paint()
      ..color = overleafBorderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = overleafBorderWidth;

    canvas
      ..drawPath(path, fillPaint)
      ..drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(_OverleafPainter oldPainter) {
    // 同 shouldReclip：进度重绘走 repaint 监听，这里只比较静态参数。
    return oldPainter.animation != animation ||
        oldPainter.color != color ||
        oldPainter.overleafBorderColor != overleafBorderColor ||
        oldPainter.overleafBorderWidth != overleafBorderWidth ||
        oldPainter.animationTransitionPoint != animationTransitionPoint ||
        oldPainter.direction != direction;
  }
}
