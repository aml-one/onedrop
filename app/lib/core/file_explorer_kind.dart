import 'package:path/path.dart' as p;

/// Visual kind for an explorer row. Folders and media thumbs override this.
enum FileExplorerKind {
  folder,
  image,
  video,
  apk,
  pdf,
  txt,
  doc,
  xml,
  xls,
  audio,
  file,
}

FileExplorerKind fileExplorerKindFor({
  required String name,
  required bool isDirectory,
}) {
  if (isDirectory) return FileExplorerKind.folder;
  final ext = p.extension(name).toLowerCase().replaceFirst('.', '');
  return fileExplorerKindForExtension(ext);
}

FileExplorerKind fileExplorerKindForExtension(String extension) {
  final ext = extension.toLowerCase().replaceFirst('.', '');
  return switch (ext) {
    'jpg' || 'jpeg' || 'png' || 'webp' || 'gif' || 'heic' || 'bmp' || 'avif' =>
      FileExplorerKind.image,
    'mp4' || 'mov' || 'webm' || 'mkv' || 'avi' || 'm4v' => FileExplorerKind.video,
    'apk' => FileExplorerKind.apk,
    'pdf' => FileExplorerKind.pdf,
    'txt' || 'md' || 'log' || 'csv' => FileExplorerKind.txt,
    'doc' || 'docx' || 'rtf' || 'odt' => FileExplorerKind.doc,
    'xml' || 'xsl' || 'xsd' => FileExplorerKind.xml,
    'xls' || 'xlsx' || 'ods' => FileExplorerKind.xls,
    'wav' || 'mp3' || 'm4a' || 'ogg' || 'flac' || 'aac' => FileExplorerKind.audio,
    _ => FileExplorerKind.file,
  };
}
