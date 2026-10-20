// lib/widgets/account_avatar.dart

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/profile_photo_cache.dart';

/// A circular account photo that keeps its picture without a network.
///
/// A bare `NetworkImage` has nowhere to get the photo from once the
/// phone is offline, and the empty circle it leaves behind looks like a
/// missing account rather than a missing connection. This asks
/// [ProfilePhotoCache] instead — which has the bytes on disk after the
/// first sight of them — and shows [fallback] only while it genuinely
/// has nothing, so an offline avatar stays a face.
class AccountAvatar extends StatefulWidget {
  const AccountAvatar({
    super.key,
    required this.photoUrl,
    required this.fallback,
    this.radius = 18,
    this.backgroundColor = Colors.white12,
  });

  /// Google's photo url; `null` or `''` means the account has none.
  final String? photoUrl;

  /// Shown until bytes arrive, and kept for accounts without a photo.
  final Widget fallback;

  final double radius;

  final Color backgroundColor;

  @override
  State<AccountAvatar> createState() => _AccountAvatarState();
}

class _AccountAvatarState extends State<AccountAvatar> {
  ImageProvider? _image;

  /// Bumped per request so a url that changes mid-flight can't have the
  /// old account's photo painted over the new one.
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(AccountAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.photoUrl != widget.photoUrl) _resolve();
  }

  Future<void> _resolve() async {
    final url = widget.photoUrl ?? '';
    if (url.isEmpty) {
      setState(() => _image = null);
      return;
    }
    final token = ++_request;
    final Uint8List? bytes = await ProfilePhotoCache.instance.bytesFor(url);
    if (!mounted || token != _request || bytes == null) return;
    setState(() => _image = MemoryImage(bytes));
  }

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: widget.radius,
      backgroundColor: widget.backgroundColor,
      backgroundImage: _image,
      child: _image == null ? widget.fallback : null,
    );
  }
}
