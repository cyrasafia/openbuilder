/// Decides *when* a file's content should be downloaded in [FileViewScreen].
///
/// Extension-based inference is the ONLY thing that uses the extension: it
/// controls download *timing*, never the render result — the renderer is
/// always chosen from the server's real `type`/`mimeType` after the download
/// completes. A wrong guess here only costs an extra tap/download, never a
/// wrong render.
///
/// Files whose extension is not recognised as definitely image/text
/// (`.gitignore`, unknown extensions, no extension, known binary extensions
/// like `.apk`/`.zip`) use [DownloadPolicy.probe]: the server exposes no
/// size-only endpoint (no HEAD/Range, `/file` and `/file/status` lack size),
/// so the download is started and the first `onReceiveProgress` callback
/// decides — small files finish and render directly (a misnamed `.gitignore`
/// → CodeView, a small `.apk` → BinaryView with bytes already in memory),
/// large files are cancelled and fall back to the binary-style preview
/// (icon + name + Download button, no "too large" dead-end).
/// This avoids forcing an extra tap on the common
/// small-text-without-a-text-extension case while still protecting against
/// huge binaries.
///
/// The cancel decision uses both the announced `Content-Length` (`total`) and
/// the bytes received so far, so it still fires when the server omits
/// `Content-Length` (chunked / HTTP2). On native, `total` is the gzipped
/// transfer size (the raw_download dio keeps compression on); on web the
/// browser owns decompression and reports decoded bytes — either way the
/// guard bounds the real cost of previewing.
///
/// See `docs/design-file-streaming.md`.
enum DownloadPolicy {
  /// Content is fetched on entry — recognised image/text extensions.
  immediate,
  /// Start downloading, inspect `Content-Length` from the first progress
  /// event, then either continue (small) or cancel and show the binary-style
  /// preview with a Download button (large). The threshold is [probeThreshold].
  probe,
}

/// Maximum size (announced `Content-Length` or bytes received so far; the
/// gzipped transfer size on native, decoded size on web) that a probed file
/// may reach before the download is cancelled and the binary-style preview
/// with a Download button is shown.
const int probeThreshold = 1 * 1024 * 1024; // 1 MiB

DownloadPolicy inferDownloadPolicy(String path) {
  final name = basenameOf(path);
  final dot = name.lastIndexOf('.');
  if (dot < 0) {
    // No extension: well-known text basenames are immediate; everything else
    // (executables, blobs, truly unknown, e.g. `.gitignore`) probes.
    return _textBasenames.contains(name.toLowerCase())
        ? DownloadPolicy.immediate
        : DownloadPolicy.probe;
  }
  final ext = name.substring(dot).toLowerCase();
  if (_imageExtensions.contains(ext) || _textExtensions.contains(ext)) {
    return DownloadPolicy.immediate;
  }
  return DownloadPolicy.probe;
}

/// The lowercased extension of [path] including the dot (e.g. `.dart`), or ''
/// when there is none. Shared so call sites don't reimplement it.
String extensionOf(String path) {
  final name = basenameOf(path);
  final dot = name.lastIndexOf('.');
  if (dot < 0) return '';
  return name.substring(dot).toLowerCase();
}

String basenameOf(String path) => path.split('/').last;

const _imageExtensions = <String>{
  '.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp',
  '.heic', '.heif', '.ico', '.tiff', '.tif', '.avif',
};

/// Well-known extensionless filenames that are reliably text. Matching them as
/// `immediate` avoids forcing a probe on the very common `Makefile` /
/// `Dockerfile` / `LICENSE` case; truly unknown names still probe.
const _textBasenames = <String>{
  'makefile', 'gnumakefile', 'dockerfile', 'containerfile',
  'license', 'licence', 'copying', 'notice', 'authors', 'contributors',
  'gemfile', 'rakefile', 'vagrantfile', 'procfile', 'berksfile',
  'thorfile', 'guardfile', 'capfile', 'fastfile', 'appfile', 'podfile',
  'brewfile', 'readme', 'changelog', 'todo',
};

const _textExtensions = <String>{
  '.dart', '.ts', '.tsx', '.js', '.jsx', '.mjs', '.py', '.go', '.rs',
  '.json', '.jsonc', '.jsonl', '.yaml', '.yml', '.md', '.markdown',
  '.sh', '.bash', '.zsh', '.sql', '.html', '.htm', '.css', '.xml',
  '.txt', '.text', '.log', '.csv', '.tsv', '.svg', '.env',
  '.ini', '.cfg', '.conf', '.toml', '.properties',
  '.c', '.cc', '.cpp', '.cxx', '.h', '.hpp', '.java', '.kt', '.kts',
  '.swift', '.rb', '.php', '.lua', '.r', '.scala', '.clj', '.ex', '.exs',
  '.erl', '.hs', '.ml', '.pl', '.pm', '.graphql', '.proto', '.vue', '.svelte',
};
