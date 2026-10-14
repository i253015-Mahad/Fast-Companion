// lib/services/profile_photo_cache.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Keeps each signed-in account's photo on disk, so the avatar still has
/// a picture when the phone has no network.
///
/// Google hands out a URL and nothing else, and the notes this app shows
/// are meant to be readable offline — an account whose photo only exists
/// on a server would come back as a blank grey circle the moment the
/// network went away, which is exactly the state the rest of the screen
/// is designed not to fall into.
///
/// So the bytes are caught the first time they are asked for and kept:
/// memory first (rows rebuild constantly), then the file, then the
/// network. The url is the cache key, so a photo that changes is a new
/// key rather than the old picture being served forever; the cost of
/// that is a file left behind when a url is retired, which is a few
/// kilobytes and not worth a sweep.
class ProfilePhotoCache {
  ProfilePhotoCache._();

  static final ProfilePhotoCache instance = ProfilePhotoCache._();

  /// Generous on purpose. This runs in the background and blocks nobody,
  /// and the phone it is aimed at sees ~600ms round trips and heavy loss
  /// on cellular — a handful of concurrent TLS handshakes under those
  /// conditions can take the better part of a minute, and a short cap
  /// means the photo is never saved at all rather than saved late.
  static const Duration _timeout = Duration(seconds: 45);

  /// Already-read bytes, keyed by url.
  final Map<String, Uint8List> _memory = {};

  /// The photo for [url] — from memory, disk or the network — or `null`
  /// when none of the three has it. Callers show something of their own
  /// in that case; `null` is "no picture", never "no account".
  Future<Uint8List?> bytesFor(String url) async {
    if (url.isEmpty) return null;

    final held = _memory[url];
    if (held != null) return held;

    final file = await _fileFor(url);
    try {
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) {
          _memory[url] = bytes;
          return bytes;
        }
      }
    } catch (e) {
      debugPrint('Profile photo cache read failed: $e');
    }

    try {
      final response = await http.get(Uri.parse(url)).timeout(_timeout);
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        return null;
      }
      _memory[url] = response.bodyBytes;
      try {
        await file.parent.create(recursive: true);
        await file.writeAsBytes(response.bodyBytes, flush: true);
      } catch (e) {
        // Still usable for this run even if the disk won't take it.
        debugPrint('Profile photo cache write failed: $e');
      }
      return response.bodyBytes;
    } catch (e) {
      debugPrint('Profile photo fetch failed: $e');
      return null;
    }
  }

  /// Fetches anything in [urls] that isn't on disk already, without
  /// making anyone wait for it.
  ///
  /// Saving a photo when its row happens to render is not enough: an
  /// account you never switched to would have nothing on the phone when
  /// the network went, and would be the one row still showing a letter.
  /// Warming the pool once at startup means every signed-in account is
  /// covered before anyone needs to look at them.
  void warmAll(Iterable<String?> urls) {
    for (final url in urls) {
      if (url == null || url.isEmpty || _memory.containsKey(url)) continue;
      unawaited(bytesFor(url));
    }
  }

  Future<File> _fileFor(String url) async {
    final dir = await getApplicationSupportDirectory();
    // Base64url of the url: stable, collision-free, and short enough to
    // be a filename on Android.
    final name = base64Url.encode(utf8.encode(url)).replaceAll('=', '');
    return File('${dir.path}/profile_photos/$name.img');
  }
}
