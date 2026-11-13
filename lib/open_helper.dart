import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

const videoDir = '/storage/emulated/0/Movies/YTSaver';
const audioDir = '/storage/emulated/0/Music/YTSaver';
const _root = '/storage/emulated/0/';

/// Opens [dir] in the system Files app. Returns false if that isn't possible.
Future<bool> openFolder(String dir) async {
  if (!dir.startsWith(_root)) return false;
  try {
    await Directory(dir).create(recursive: true);
  } catch (_) {}
  final rel = dir.substring(_root.length);
  final uri = Uri.parse(
      'content://com.android.externalstorage.documents/document/'
      'primary%3A${Uri.encodeComponent(rel)}');
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

Future<void> openFolderWithFeedback(BuildContext context, String dir) async {
  final ok = await openFolder(dir);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not open the Files app. Folder: $dir')),
    );
  }
}