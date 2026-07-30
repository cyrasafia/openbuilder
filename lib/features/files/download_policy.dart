/// Decides *when* a file's content should be downloaded in [FileViewScreen].
///
/// Extension-based inference is the ONLY thing that uses the extension: it
/// controls download *timing* (immediate vs on-demand), never the render
/// result — the renderer is always chosen from the server's real
/// `type`/`mimeType` after the download completes. A wrong guess here only
/// costs an extra tap/download, never a wrong render.
///
/// See `docs/design-file-streaming.md`.
enum DownloadPolicy {
  /// Content is fetched on entry (image/text that needs bytes to render).
  immediate,
  /// Show a placeholder without downloading; fetch on user tap (binary/unknown).
  onDemand,
}

DownloadPolicy inferDownloadPolicy(String path) {
  final name = basenameOf(path);
  final dot = name.lastIndexOf('.');
  if (dot < 0) {
    // No extension: well-known text basenames are immediate; everything else
    // (executables, blobs, truly unknown) stays onDemand.
    return _textBasenames.contains(name.toLowerCase())
        ? DownloadPolicy.immediate
        : DownloadPolicy.onDemand;
  }
  final ext = name.substring(dot).toLowerCase();
  if (_imageExtensions.contains(ext) || _textExtensions.contains(ext)) {
    return DownloadPolicy.immediate;
  }
  return DownloadPolicy.onDemand;
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
/// `immediate` avoids forcing a placeholder + extra tap on the very common
/// `Makefile` / `Dockerfile` / `LICENSE` case; truly unknown names still defer.
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
