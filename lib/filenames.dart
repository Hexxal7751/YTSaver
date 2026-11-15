import 'dart:io';

const kDefaultTemplate = '{title} [{quality}]';

/// Placeholders the filename template understands.
const kTemplateTags = ['{title}', '{quality}', '{channel}', '{id}', '{date}'];

/// Makes a string safe to use as a file name.
String safeName(String s, {int max = 120}) {
  var r = s.replaceAll(RegExp(r'[\\/:*?"<>|\u0000-\u001f]'), '_');
  r = r.replaceAll(RegExp(r'\s+'), ' ').trim();
  r = r.replaceFirst(RegExp(r'^\.+'), '');
  if (r.runes.length > max) {
    r = String.fromCharCodes(r.runes.take(max)).trim();
  }
  return r;
}

/// Fills the template, e.g. "{title} [{quality}]" -> "My video [1080p + 128kbps]".
String renderName(
  String template, {
  required String title,
  required String quality,
  required String channel,
  required String id,
}) {
  final d = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final date = '${d.year}-${two(d.month)}-${two(d.day)}';
  final tpl = template.trim().isEmpty ? kDefaultTemplate : template;
  var out = tpl
      .replaceAll('{title}', title)
      .replaceAll('{quality}', quality)
      .replaceAll('{channel}', channel)
      .replaceAll('{id}', id)
      .replaceAll('{date}', date);
  out = safeName(out);
  if (out.isEmpty) out = safeName(title);
  if (out.isEmpty) out = id;
  return out;
}

/// "dir/base.ext", or "dir/base (1).ext" etc. if that already exists.
String uniquePath(String dir, String base, String ext) {
  var p = '$dir/$base.$ext';
  var i = 1;
  while (File(p).existsSync() && i < 1000) {
    p = '$dir/$base ($i).$ext';
    i++;
  }
  return p;
}